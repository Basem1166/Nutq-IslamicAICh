import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

/// Output of [MualemFeatureExtractor]: a flat row-major `[seqLen * 160]` buffer
/// (the `[1, seqLen, 160]` tensor with the batch dim implicit) plus [seqLen].
class FeatureResult {
  FeatureResult(this.features, this.seqLen);
  final Float32List features;
  final int seqLen;
}

/// Dart re-implementation of HuggingFace `SeamlessM4TFeatureExtractor`
/// (used by `Wav2Vec2BertProcessor`) — turns a 16 kHz mono waveform into the
/// `input_features` tensor the Mualem ONNX model expects.
///
/// Pipeline (mirrors `_extract_fbank_features` + `__call__`):
///   1. scale waveform by 2^15 (Kaldi 16-bit convention),
///   2. frame: length 400, hop 160, no centering,
///   3. per frame: remove DC offset, preemphasis 0.97, povey window,
///   4. 512-point FFT, power spectrum (|.|^2), 257 bins,
///   5. kaldi-scale mel filterbank (80 filters, 20–8000 Hz), max(mel_floor),
///   6. natural log,
///   7. (optional) per-mel-bin zero-mean/unit-var normalization over time,
///   8. stride-2 frame stacking: (T, 80) -> (T//2, 160).
///
/// NOTE: step 7 ([normalizePerBin]) is the one detail that cannot be confirmed
/// from the model file alone. Wav2Vec2-BERT applies a LayerNorm to the input
/// features internally, so this defaults to **off**. If golden-vector
/// validation against the Python extractor shows a mismatch, flip this flag.
class MualemFeatureExtractor {
  MualemFeatureExtractor({this.normalizePerBin = true}) {
    _window = _poveyWindow(frameLength);
    _melFiltersT = _buildMelFiltersTransposed();
    _fft = FFT(fftLength);
  }

  static const int sampleRate = 16000;
  static const int frameLength = 400; // 25 ms
  static const int hopLength = 160; // 10 ms
  static const int fftLength = 512;
  static const int numFreqBins = fftLength ~/ 2 + 1; // 257
  static const int numMelBins = 80;
  static const int stride = 2;
  static const double preemphasis = 0.97;
  static const double melFloor = 1.192092955078125e-07;
  static const double minFrequency = 20.0;
  static const double maxFrequency = 8000.0;

  final bool normalizePerBin;

  late final Float64List _window; // length 400
  late final List<Float64List> _melFiltersT; // [80][257]
  late final FFT _fft;

  /// Converts a normalized (-1..1) mono waveform into `input_features`.
  FeatureResult extract(Float32List waveform) {
    final n = waveform.length;
    if (n < frameLength) {
      return FeatureResult(Float32List(0), 0);
    }
    final numFrames = (n - frameLength) ~/ hopLength + 1;

    // (numFrames, 80) log-mel features.
    final mel = List<Float64List>.generate(
      numFrames,
      (_) => Float64List(numMelBins),
      growable: false,
    );

    final buffer = Float64List(fftLength); // zero-padded frame for FFT
    for (var f = 0; f < numFrames; f++) {
      final start = f * hopLength;

      // Copy frame and scale by 2^15.
      var mean = 0.0;
      for (var i = 0; i < frameLength; i++) {
        final s = waveform[start + i] * 32768.0;
        buffer[i] = s;
        mean += s;
      }
      mean /= frameLength;

      // Remove DC offset.
      for (var i = 0; i < frameLength; i++) {
        buffer[i] -= mean;
      }

      // Preemphasis (in place): b[i] -= 0.97*b[i-1] going high->low, b[0]*=0.03.
      for (var i = frameLength - 1; i >= 1; i--) {
        buffer[i] -= preemphasis * buffer[i - 1];
      }
      buffer[0] *= (1.0 - preemphasis);

      // Window, then zero-pad the tail (frameLength..fftLength).
      for (var i = 0; i < frameLength; i++) {
        buffer[i] *= _window[i];
      }
      for (var i = frameLength; i < fftLength; i++) {
        buffer[i] = 0.0;
      }

      // Real FFT -> power spectrum (257 bins).
      final spectrum = _fft.realFft(buffer);
      final power = Float64List(numFreqBins);
      for (var k = 0; k < numFreqBins; k++) {
        final re = spectrum[k].x;
        final im = spectrum[k].y;
        power[k] = re * re + im * im;
      }

      // Mel projection + floor + log.
      final row = mel[f];
      for (var m = 0; m < numMelBins; m++) {
        final filt = _melFiltersT[m];
        var acc = 0.0;
        for (var k = 0; k < numFreqBins; k++) {
          acc += filt[k] * power[k];
        }
        row[m] = math.log(acc < melFloor ? melFloor : acc);
      }
    }

    if (normalizePerBin) {
      _normalizePerBin(mel);
    }

    // Stride-2 stacking: drop trailing odd frame, (T,80) -> (T//2,160).
    final seqLen = numFrames ~/ stride;
    final out = Float32List(seqLen * numMelBins * stride);
    for (var t = 0; t < seqLen; t++) {
      final a = mel[t * 2];
      final b = mel[t * 2 + 1];
      final base = t * 160;
      for (var j = 0; j < numMelBins; j++) {
        out[base + j] = a[j];
        out[base + numMelBins + j] = b[j];
      }
    }
    return FeatureResult(out, seqLen);
  }

  void _normalizePerBin(List<Float64List> mel) {
    final numFrames = mel.length;
    if (numFrames == 0) return;
    const eps = 1e-7;
    for (var m = 0; m < numMelBins; m++) {
      var sum = 0.0;
      for (var f = 0; f < numFrames; f++) {
        sum += mel[f][m];
      }
      final mean = sum / numFrames;
      var varAcc = 0.0;
      for (var f = 0; f < numFrames; f++) {
        final d = mel[f][m] - mean;
        varAcc += d * d;
      }
      final std = math.sqrt(varAcc / numFrames + eps);
      for (var f = 0; f < numFrames; f++) {
        mel[f][m] = (mel[f][m] - mean) / std;
      }
    }
  }

  // ── Povey window: hanning(length)^0.85, non-periodic ──────────────────────
  static Float64List _poveyWindow(int length) {
    final w = Float64List(length);
    for (var i = 0; i < length; i++) {
      // np.hanning(length): 0.5 - 0.5*cos(2*pi*i/(length-1))
      final hann = 0.5 - 0.5 * math.cos(2 * math.pi * i / (length - 1));
      w[i] = math.pow(hann, 0.85).toDouble();
    }
    return w;
  }

  // ── Kaldi-scale mel filterbank, triangularize_in_mel_space=True ───────────
  // Faithful port of transformers.audio_utils.mel_filter_bank. Returns the
  // transposed bank [80][257] (zero row padded at bin 256) for fast projection.
  static List<Float64List> _buildMelFiltersTransposed() {
    // mel_filter_bank is called with num_frequency_bins=256, then HF pads one
    // zero row -> 257. We build 256 then treat bin 256 as 0.
    const numFreqBinsUsed = 256;

    double hzToMel(double hz) => 1127.0 * math.log(1.0 + hz / 700.0);

    final melMin = hzToMel(minFrequency);
    final melMax = hzToMel(maxFrequency);

    // filter_freqs in mel space: linspace(melMin, melMax, numMelBins + 2).
    final filterFreqs = Float64List(numMelBins + 2);
    for (var i = 0; i < numMelBins + 2; i++) {
      filterFreqs[i] = melMin + (melMax - melMin) * i / (numMelBins + 1);
    }

    // fft_freqs in mel space: hzToMel(fftBinWidth * arange(256)).
    final fftBinWidth = sampleRate / (numFreqBinsUsed * 2); // 31.25 Hz
    final fftFreqs = Float64List(numFreqBinsUsed);
    for (var k = 0; k < numFreqBinsUsed; k++) {
      fftFreqs[k] = hzToMel(fftBinWidth * k);
    }

    // filter_diff = diff(filter_freqs) (length numMelBins+1).
    final filterDiff = Float64List(numMelBins + 1);
    for (var i = 0; i < numMelBins + 1; i++) {
      filterDiff[i] = filterFreqs[i + 1] - filterFreqs[i];
    }

    // Triangular bank: for each freq bin k and filter m,
    //   down = -(filter_freqs[m]   - fft_freqs[k]) / filter_diff[m]
    //   up   =  (filter_freqs[m+2] - fft_freqs[k]) / filter_diff[m+1]
    //   value = max(0, min(down, up))
    // Stored transposed as bank[m][k], with bin 256 left as 0.
    final bank = List<Float64List>.generate(
      numMelBins,
      (_) => Float64List(numFreqBins), // 257, last stays 0
      growable: false,
    );
    for (var m = 0; m < numMelBins; m++) {
      final row = bank[m];
      for (var k = 0; k < numFreqBinsUsed; k++) {
        final slopeDown = filterFreqs[m] - fftFreqs[k];
        final slopeUp = filterFreqs[m + 2] - fftFreqs[k];
        final down = -slopeDown / filterDiff[m];
        final up = slopeUp / filterDiff[m + 1];
        final v = down < up ? down : up;
        row[k] = v > 0 ? v : 0.0;
      }
    }
    return bank;
  }
}
