import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Records microphone audio as 16 kHz mono PCM16 WAV and exposes it as a
/// normalized [Float32List] suitable for the Mualem feature extractor.
///
/// The Mualem ONNX model expects features derived from a 16 kHz mono signal
/// (see `SeamlessM4TFeatureExtractor`, sampling_rate=16000), so we record at
/// exactly that rate to avoid any resampling.
class AudioRecorderService {
  static const int sampleRate = 16000;

  final AudioRecorder _recorder = AudioRecorder();
  String? _lastPath;

  /// Whether microphone permission has been granted.
  Future<bool> hasPermission() => _recorder.hasPermission();

  /// True while a recording is in progress.
  Future<bool> get isRecording => _recorder.isRecording();

  /// Starts recording into a temp WAV file. Throws if permission is denied.
  Future<void> start() async {
    if (!await _recorder.hasPermission()) {
      throw Exception('Microphone permission denied');
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/mualem_${DateTime.now().millisecondsSinceEpoch}.wav';
    _lastPath = path;
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: sampleRate,
        numChannels: 1,
      ),
      path: path,
    );
  }

  /// Stops recording and returns the path of the written WAV file (or null).
  Future<String?> stop() async {
    final path = await _recorder.stop();
    return path ?? _lastPath;
  }

  /// Starts a live PCM stream and yields normalized [-1, 1] mono [Float32List]
  /// chunks at 16 kHz — the format the streaming recitation session consumes.
  ///
  /// Throws if microphone permission is denied. Call [stopStream] to end it.
  /// Don't mix with [start]/[stop]; one [AudioRecorder] does one thing at a
  /// time.
  Future<Stream<Float32List>> startStream() async {
    if (!await _recorder.hasPermission()) {
      throw Exception('Microphone permission denied');
    }
    final raw = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
      ),
    );
    return _decodePcm16Stream(raw);
  }

  /// Stops a stream started with [startStream].
  Future<void> stopStream() async {
    await _recorder.stop();
  }

  /// Decodes a raw PCM16-LE byte stream into normalized [Float32List] chunks,
  /// carrying a split sample across chunk boundaries when a chunk ends on an
  /// odd byte.
  static Stream<Float32List> _decodePcm16Stream(Stream<Uint8List> raw) async* {
    int? pending; // leftover low byte from a previous chunk, if any
    const scale = 1.0 / 32768.0;

    await for (final chunk in raw) {
      Uint8List bytes = chunk;
      if (pending != null) {
        final combined = Uint8List(bytes.length + 1);
        combined[0] = pending;
        combined.setRange(1, combined.length, bytes);
        bytes = combined;
        pending = null;
      }

      final usableBytes = bytes.length - (bytes.length.isOdd ? 1 : 0);
      if (bytes.length.isOdd) {
        pending = bytes[bytes.length - 1];
      }
      if (usableBytes == 0) continue;

      final n = usableBytes ~/ 2;
      final bd = ByteData.sublistView(bytes, 0, usableBytes);
      final out = Float32List(n);
      for (var i = 0; i < n; i++) {
        out[i] = bd.getInt16(i * 2, Endian.little) * scale;
      }
      yield out;
    }
  }

  /// Releases native resources.
  Future<void> dispose() => _recorder.dispose();

  /// Reads a 16-bit PCM WAV file and returns mono samples normalized to
  /// [-1, 1]. Handles the standard 44-byte header but scans the chunk list so
  /// it also works when extra chunks (e.g. LIST) precede the `data` chunk.
  static Future<Float32List> readWavAsFloat32(String path) async {
    final bytes = await File(path).readAsBytes();
    return decodeWavPcm16(bytes);
  }

  /// Decodes PCM16 WAV bytes into a normalized [Float32List] in [-1, 1].
  static Float32List decodeWavPcm16(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);

    if (bytes.lengthInBytes < 12 ||
        _tag(bytes, 0) != 'RIFF' ||
        _tag(bytes, 8) != 'WAVE') {
      throw const FormatException('Not a RIFF/WAVE file');
    }

    int numChannels = 1;
    int bitsPerSample = 16;
    int dataOffset = -1;
    int dataLength = 0;

    // Walk the chunk list starting right after the "WAVE" tag.
    int pos = 12;
    while (pos + 8 <= bytes.lengthInBytes) {
      final id = _tag(bytes, pos);
      final size = data.getUint32(pos + 4, Endian.little);
      final body = pos + 8;
      if (id == 'fmt ') {
        numChannels = data.getUint16(body + 2, Endian.little);
        bitsPerSample = data.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        dataOffset = body;
        dataLength = size;
        break;
      }
      // Chunks are word-aligned (padded to even size).
      pos = body + size + (size.isOdd ? 1 : 0);
    }

    if (dataOffset < 0) {
      throw const FormatException('WAV has no data chunk');
    }
    if (bitsPerSample != 16) {
      throw FormatException('Only PCM16 WAV supported (got $bitsPerSample-bit)');
    }

    // Clamp to the actual byte length in case the header lies.
    final available = bytes.lengthInBytes - dataOffset;
    if (dataLength <= 0 || dataLength > available) dataLength = available;

    final totalSamples = dataLength ~/ 2;
    final frames = totalSamples ~/ numChannels;
    final out = Float32List(frames);
    const scale = 1.0 / 32768.0;

    for (var i = 0; i < frames; i++) {
      // Downmix to mono by averaging channels.
      var acc = 0;
      for (var c = 0; c < numChannels; c++) {
        acc += data.getInt16(dataOffset + (i * numChannels + c) * 2, Endian.little);
      }
      out[i] = (acc / numChannels) * scale;
    }
    return out;
  }

  static String _tag(Uint8List b, int offset) =>
      String.fromCharCodes(b.sublist(offset, offset + 4));
}
