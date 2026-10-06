/// Unit tests for the repetition (H2) branch of [classifyPhrase], focused on
/// the **clean-go-back rule** added to make breath-pause-then-resume robust.
///
/// Background
/// ──────────
/// Repetition can be decided two ways (see `phrase_classifier.dart` Rule 3):
///   (a) the **margin rule** — H2 beats forward continuation (H1) by at least
///       [PhraseClassifierConfig.repetitionMargin]; and
///   (b) the **clean-go-back rule** — H2 is a clean match to an earlier word
///       (PER ≤ [PhraseClassifierConfig.goodPerThreshold]) and is *strictly*
///       better than H1, even when the margin isn't met.
///
/// Rule (b) exists because an imperfect re-recitation after a breath often
/// doesn't clear the full margin, which previously made the phrase fall through
/// to `continuation` and commit the re-recited audio onto the wrong later word.
///
/// Isolating rule (b)
/// ──────────────────
/// To prove a test exercises the *clean-go-back* rule and not the margin rule,
/// these tests run with `repetitionMargin: 0.9` — a value so large the margin
/// rule effectively can't fire for a realistic phrase. Any `repetition` result
/// under that config must therefore come from the clean-go-back rule. Each test
/// also asserts the margin was genuinely unmet (via independently computed H1
/// and H2 PERs) so the isolation is explicit, not assumed.
///
/// Reference tokens are QPS (Arabic) because PER is scored on `chunkPhonemes`
/// output (ASCII would collapse every PER to 0). See `fake_reference_loader`.
library;

import 'package:quran_recitation_core/quran_recitation_core.dart';
import 'package:test/test.dart';

import 'support/fake_reference_loader.dart';

/// Word spans for an ayah whose words are the whitespace-separated [text]
/// tokens (each token's reference phonemes equal the token itself).
List<WordSpan> spansFor(String text) =>
    fakeAyahReference(sura: 1, ayah: 1, text: text).spans;

void main() {
  // Margin so large the margin rule can't fire for a realistic phrase; any
  // repetition under this config is the clean-go-back rule's doing.
  const marginDisabled = PhraseClassifierConfig(repetitionMargin: 0.9);

  group('clean-go-back rule', () {
    test('a clean re-recitation of an earlier word is repetition even when the '
        'margin is not met', () {
      // w0='تَ', w1='قَلَمَ', w2='قَلَمَسَ'. The reciter is at word 2 and goes
      // back to cleanly re-recite word 1.
      final spans = spansFor('تَ قَلَمَ قَلَمَسَ');
      const hyp = 'قَلَمَ';
      const currentWordIdx = 2;

      // Independently score H2 (back-scan) and H1 (forward continuation) so we
      // can prove the margin is unmet and H2 is a clean go-back.
      final rep = scoreRepetition(
        phraseHyp: hyp,
        wordSpans: spans,
        currentWordIdx: currentWordIdx,
      );
      final h1 = alignPhraseToWords(
        phraseHyp: hyp,
        wordSpans: spans,
        startIdx: currentWordIdx,
      );
      expect(rep, isNotNull);
      expect(rep!.startIdx, 1, reason: 'best go-back is word 1');
      expect(
        rep.alignment.overallPer,
        lessThanOrEqualTo(marginDisabled.goodPerThreshold),
        reason: 'H2 must be a clean match to the earlier word',
      );
      expect(
        h1.overallPer - rep.alignment.overallPer,
        lessThan(marginDisabled.repetitionMargin),
        reason: 'the margin must be unmet so only the clean-go-back rule '
            'can produce repetition',
      );
      expect(
        rep.alignment.overallPer,
        lessThan(h1.overallPer),
        reason: 'H2 must be strictly better than H1 for the clean rule',
      );

      final result = classifyPhrase(
        phraseHyp: hyp,
        wordSpans: spans,
        currentWordIdx: currentWordIdx,
        config: marginDisabled,
      );
      expect(result.decision, PhraseDecision.repetition);
      expect(result.startWordIdx, 1);
    });
  });

  group('clean-go-back rule does not steal genuine continuations', () {
    test('a clean FORWARD recitation stays continuation (H2 is not clean)', () {
      // Reciter has done word 0 and is reciting word 1 forward — not a go-back.
      final spans = spansFor('قَلَ رَبَ سَ');
      const hyp = 'رَبَ';
      const currentWordIdx = 1;

      final rep = scoreRepetition(
        phraseHyp: hyp,
        wordSpans: spans,
        currentWordIdx: currentWordIdx,
      );
      // The only earlier word is word 0 ('قَلَ'), which 'رَبَ' does not match,
      // so H2 is not a clean go-back.
      expect(rep, isNotNull);
      expect(
        rep!.alignment.overallPer,
        greaterThan(marginDisabled.goodPerThreshold),
      );

      final result = classifyPhrase(
        phraseHyp: hyp,
        wordSpans: spans,
        currentWordIdx: currentWordIdx,
        config: marginDisabled,
      );
      expect(result.decision, PhraseDecision.continuation);
      expect(result.startWordIdx, currentWordIdx);
    });

    test('an equally-clean earlier word does NOT win (strict < guard)', () {
      // w1 and w2 are identical, so the phrase matches the current word (H1)
      // exactly as well as the earlier word (H2). The strict `H2 < H1` guard
      // must keep this a continuation rather than stalling on a repetition.
      final spans = spansFor('تَ قَلَمَ قَلَمَ');
      const hyp = 'قَلَمَ';
      const currentWordIdx = 2;

      final rep = scoreRepetition(
        phraseHyp: hyp,
        wordSpans: spans,
        currentWordIdx: currentWordIdx,
      );
      final h1 = alignPhraseToWords(
        phraseHyp: hyp,
        wordSpans: spans,
        startIdx: currentWordIdx,
      );
      expect(rep, isNotNull);
      expect(
        rep!.alignment.overallPer,
        equals(h1.overallPer),
        reason: 'identical words ⇒ H2 == H1, so the strict guard blocks it',
      );

      final result = classifyPhrase(
        phraseHyp: hyp,
        wordSpans: spans,
        currentWordIdx: currentWordIdx,
        config: marginDisabled,
      );
      expect(result.decision, PhraseDecision.continuation);
    });
  });
}
