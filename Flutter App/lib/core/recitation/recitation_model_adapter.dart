import 'package:flutter/foundation.dart';
import 'package:quran_recitation_core/quran_recitation_core.dart';

import 'ctc_decoder.dart';
import 'feature_extractor.dart';
import 'mualem_model.dart';
import 'sifat_mapping.dart';

/// Bridges the app's synchronous `feature_extractor` + `mualem_model` +
/// `ctc_decoder` trio to the [RecitationModel] interface that
/// [AdaptiveStreamingMuaalem] drives.
///
/// One `run` does: audio → log-mel features → 11-level CTC logits → frame
/// windowed greedy decode of the phoneme head, plus per-chunk sifat labels for
/// the ten sifat heads. The raw logits are cached so [decodeFromLastLogits] can
/// re-decode a different frame range (seam recovery) without re-running ONNX.
class RecitationModelAdapter implements RecitationModel {
  RecitationModelAdapter({
    required this.model,
    required this.decoder,
    required this.extractor,
  });

  final MualemModel model;
  final CtcDecoder decoder;
  final MualemFeatureExtractor extractor;

  /// Sifat head names in the order the session expects to read them.
  static const List<String> sifatLevels = <String>[
    'hams_or_jahr',
    'shidda_or_rakhawa',
    'tafkheem_or_taqeeq',
    'itbaq',
    'safeer',
    'qalqla',
    'tikraar',
    'tafashie',
    'istitala',
    'ghonna',
  ];

  /// Defined to improve the accuracy of specific phonemes with unique sifa.
  /// Ported from Python `Nutq.SIFAT_POSITIVE_PHONEMES`.
  static const Map<String, String> sifatPositivePhonemes = <String, String>{
    'tikraar': 'ر',
    'tafashie': 'ش',
    'qalqla': 'قطبجد',
    'istitala': 'ض',
    'safeer': 'صزس',
    'itbaq': 'صضطظ',
  };

  /// Sifat negative labels from the model's vocab (English).
  /// Ported from Python `nutq.py`.
  static const Map<String, String> sifatNegativeLabels = <String, String>{
    'tikraar': 'not_mokarar',
    'tafashie': 'not_motafashie',
    'qalqla': 'not_moqalqal',
    'istitala': 'not_mostateel',
    'safeer': 'no_safeer',
    'itbaq': 'monfateh',
  };

  /// Logits from the most recent [run], keyed by level. Cached for seam
  /// recovery via [decodeFromLastLogits].
  Map<String, List<List<double>>>? _lastLogits;

  @override
  MuaalemOutput run({
    required Float32List audio,
    required int frameStart,
    required int frameEnd,
  }) {
    final features = extractor.extract(audio);
    if (features.seqLen == 0) {
      _lastLogits = null;
      return const MuaalemOutput(
        phonemes: PhonemeUnit(ids: <int>[], text: ''),
      );
    }

    final logits = model.run(features);
    _lastLogits = logits;

    final phon = logits['phonemes'];
    if (phon == null || phon.isEmpty) {
      return const MuaalemOutput(
        phonemes: PhonemeUnit(ids: <int>[], text: ''),
      );
    }

    if (kDebugMode) {
      final expected = samplesToCtcFrames(audio.length);
      if (expected != phon.length) {
        debugPrint(
          '[stream] CTC frame mismatch: samplesToCtcFrames=$expected '
          'model_time=${phon.length} (audio=${audio.length} samples). '
          'Frame windowing may be off — check samples_to_ctc_frames constants.',
        );
      }
    }

    final tokens =
        decoder.decodeTokens(phon, frameStart: frameStart, frameEnd: frameEnd);
    final unit = _phonemeUnit(tokens);

    debugPrint('[stream] decoded chunk: "${unit.text}" (tokens=${tokens.length}, frames=$frameStart-$frameEnd)');

    if (tokens.isEmpty) {
      return MuaalemOutput(phonemes: unit);
    }
    return MuaalemOutput(
      phonemes: unit,
      sifat: _decodeSifat(logits, unit.text, tokens),
    );
  }

  @override
  PhonemeUnit? decodeFromLastLogits({
    required int frameStart,
    required int frameEnd,
  }) {
    final phon = _lastLogits?['phonemes'];
    if (phon == null || phon.isEmpty) return null;
    final tokens =
        decoder.decodeTokens(phon, frameStart: frameStart, frameEnd: frameEnd);
    if (tokens.isEmpty) return null;
    return _phonemeUnit(tokens);
  }

  @override
  String vocabLookup(String level, int id) {
    final raw = decoder.tokenFor(level, id) ?? '';
    // The session compares predicted sifat against the phonetizer's English
    // literals, so normalize the model's Arabic vocab tokens (e.g. '[جهر]') to
    // their English form ('jahr') here — the single bridge point between the
    // two vocabularies. Phoneme lookups (level == 'phonemes') pass through
    // unchanged, since normalizeSifatToken only maps the 10 sifat heads.
    return normalizeSifatToken(level, raw);
  }

  PhonemeUnit _phonemeUnit(List<CtcToken> tokens) {
    final ids = <int>[];
    final frames = <int>[];
    final probs = <double>[];
    final buf = StringBuffer();
    for (final t in tokens) {
      ids.add(t.id);
      frames.add(t.peakFrame);
      probs.add(t.prob);
      buf.write(decoder.tokenFor('phonemes', t.id) ?? '');
    }
    final text = buf.toString();
    // Ensure 'tokens' and 'text' stay logically synced even if some tokens are empty.
    // The tokens list passed to _decodeSifat must be exactly what produced this text.
    return PhonemeUnit(
      ids: ids,
      text: text,
      frames: frames,
      probabilities: probs,
    );
  }

  /// Builds per-chunk sifat outputs. Each level's `ids[ci]` aligns with the
  /// ci-th chunk of [phonemeText] (the same chunking the session re-derives),
  /// read as the majority class over that chunk's CTC frame span.
  Map<String, SifaUnit> _decodeSifat(
    Map<String, List<List<double>>> logits,
    String phonemeText,
    List<CtcToken> tokens,
  ) {
    final chunks = chunkPhonemes(phonemeText);
    if (chunks.isEmpty) return const <String, SifaUnit>{};

    // Map character index -> token index. This is necessary because some tokens
    // in the vocab (like 'اا') are multiple characters long, so the char index
    // is not equal to the token index.
    final charToTokenIdx = <int, int>{};
    var currentCharPos = 0;
    for (var i = 0; i < tokens.length; i++) {
      final tText = decoder.tokenFor('phonemes', tokens[i].id) ?? '';
      if (tText.isEmpty) {
        // Token produces no text (e.g. blank, shouldn't happen here but for safety)
        continue;
      }
      for (var j = 0; j < tText.length; j++) {
        charToTokenIdx[currentCharPos + j] = i;
      }
      currentCharPos += tText.length;
    }

    final chunkTokenIdxs = <int>[];
    var pointer = 0;
    for (final chunk in chunks) {
      var charIdx = phonemeText.indexOf(chunk, pointer);
      if (charIdx == -1) charIdx = pointer;

      // Use the character-to-token mapping to find which token starts this chunk.
      // Guard against out-of-bounds charIdx if the mapping is incomplete.
      final tokenIdx = charToTokenIdx[charIdx];
      if (tokenIdx != null) {
        chunkTokenIdxs.add(tokenIdx);
      } else {
        // If we can't find a token for this character, use a safe fallback -1
        // which will trigger the padding path in the loop below.
        chunkTokenIdxs.add(-1);
      }

      pointer = charIdx + chunk.length;
    }

    final out = <String, SifaUnit>{};
    for (final level in sifatLevels) {
      final lvlLogits = logits[level];
      if (lvlLogits == null || lvlLogits.isEmpty) continue;

      final ids = <int>[];
      final probs = <double>[];

      for (var i = 0; i < chunkTokenIdxs.length; i++) {
        final tokenIdx = chunkTokenIdxs[i];
        if (tokenIdx >= 0 && tokenIdx < tokens.length) {
          final currFrame = tokens[tokenIdx].peakFrame;
          // Windowed max pooling: ±1 frame around the phoneme peak.
          final bufferedStart = currFrame - 1;
          final bufferedEnd = currFrame + 2;

          final cls =
              decoder.maxPoolClassOverSpan(lvlLogits, bufferedStart, bufferedEnd);
          ids.add(cls.id);
          probs.add(cls.prob);
        } else {
          // Fallback: pad if out-of-range or invalid index
          ids.add(0);
          probs.add(0.0);
        }
      }

      // Apply sifat constraints (e.g. only 'raa' can have 'tikraar').
      final constraint = sifatPositivePhonemes[level];
      final negLabel = sifatNegativeLabels[level];
      if (constraint != null && negLabel != null) {
        for (var i = 0; i < chunks.length; i++) {
          if (i >= ids.length) break;
          final base = chunks[i].isNotEmpty ? chunks[i][0] : '';
          if (!constraint.contains(base)) {
            // Force negative label if the phoneme doesn't support this sifat.
            // We need to look up the ID for the negative label.
            final negId = _findIdByToken(level, negLabel);
            if (negId != null) {
              ids[i] = negId;
            }
          }
        }
      }

      out[level] = SifaUnit(ids: ids, probabilities: probs);
    }
    return out;
  }

  int? _findIdByToken(String level, String token) {
    // Brute-force reverse lookup in the decoder's vocab.
    for (var id = 0; id < 100; id++) {
      // 100 is safe for sifat heads
      final t = decoder.tokenFor(level, id);
      if (t == null) continue;
      // The vocab stores Arabic tokens like "[لا تكرار]", while the
      // negativeLabels map uses English literals. We need to normalize.
      if (normalizeSifatToken(level, t) == token) {
        return id;
      }
    }
    return null;
  }
}
