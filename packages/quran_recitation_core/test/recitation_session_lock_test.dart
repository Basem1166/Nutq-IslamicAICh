/// Regression guards for the **removed** word-lock mechanism.
///
/// The session used to "lock" on a mis-recited word: it stopped advancing,
/// set `AyahStatus.lockedOnFirstWord`, and forced the reciter to re-recite the
/// same word before moving on. That blocking behavior was the main source of
/// lag (every lock dragged the VAD into a Madd-stretched silence window and
/// reset the streamer), so it was ripped out entirely. The new contract is:
///
///   1. **No permanent lock** — at a phrase boundary (the reciter paused, so
///      the phrase is fully spoken) the session always commits the matched
///      words with a pure PER-based status and advances; it never demands a
///      re-recitation before moving on, however bad the score.
///   2. **The eager path HOLDS, it doesn't cascade** — while the reciter is
///      mid-phrase, if they stop on a word the eager path withholds the commit
///      instead of fabricating red results for words that were never recited
///      (and surfaces a non-committing live hint). The pointer waits on the
///      word being recited rather than marching forward marking everything red.
///      This is a transient hold, not a lock: the next boundary resolves it.
///   3. **Red marking preserved** — a severe error (PER ≥
///      [PhraseClassifierConfig.wordZeroLockPer]) still surfaces as
///      [WordStatus.locked] (red in the UI). It is now a colour tier only, not
///      a blocking state.
///   4. **Repetitions allowed** — re-reciting an earlier word still replaces
///      its stored result in place (when at least as good) and bumps the
///      repetition count.
///
/// These tests pin those guarantees so locking can't silently creep back —
/// and so the eager hold can't be over-removed into a red cascade again.
///
/// Determinism strategy
/// ────────────────────
/// The real pipeline (ONNX CTC + Silero VAD) is replaced by scripted fakes
/// (see `test/support`). Audio content is irrelevant: the [ScriptedVadBackend]
/// returns one scripted P(speech) per 512-sample window and the
/// [ScriptedRecitationModel] emits one scripted phoneme string per streamer
/// commit. A huge `baseChunkS` ("flush-only" regime) means `streamer.process`
/// never hits a commit milestone, so the ONLY commit is the VAD boundary
/// `flush()` — exactly one scripted string per phrase, which keeps the
/// classify → emit path deterministic.
///
/// All reference tokens are **QPS (Arabic)** because the session scores PER on
/// `chunkPhonemes` output, whose chunker only recognises Arabic core letters
/// (ASCII would collapse every PER to 0). See `fake_reference_loader.dart`.
library;

import 'dart:typed_data';

import 'package:quran_recitation_core/quran_recitation_core.dart';
import 'package:test/test.dart';

import 'support/fake_recitation_model.dart';
import 'support/fake_reference_loader.dart';
import 'support/scripted_vad_backend.dart';

/// Everything a test needs to drive one session.
typedef Harness = ({
  RecitationSession session,
  ScriptedRecitationModel model,
  ScriptedVadBackend vad,
  VadGate gate,
});

/// Wires the scripted fakes into a [RecitationSession].
///
/// [texts] maps `(sura, ayah)` → QPS ayah text (whitespace-separated words).
/// [cfg] is the streamer config (controls the commit regime).
Harness makeHarness(Map<(int, int), String> texts, AdaptiveConfig cfg) {
  final model = ScriptedRecitationModel();
  final streamer = AdaptiveStreamingMuaalem(model: model, cfg: cfg);
  final vadBackend = ScriptedVadBackend();
  // energySpeechFloor: 0 — the scripted backend fully dictates speech/silence;
  // the RMS override would otherwise re-classify our all-zero audio.
  final gate = VadGate(backend: vadBackend, energySpeechFloor: 0.0);
  final session = RecitationSession(
    streamer: streamer,
    referenceLoader: FakeReferenceLoader(texts),
    vadGate: gate,
    sessionConfig: const SessionConfig(vadEnabled: true),
  );
  return (session: session, model: model, vad: vadBackend, gate: gate);
}

/// Feeds one chunk of [speech] speech windows followed by [silence] silence
/// windows. The scripted VAD reads exactly one probability per 512-sample
/// window, so the audio length is kept a precise multiple of the window size
/// to stay in lock-step with the script.
void feed(
  Harness h, {
  int speech = 0,
  int silence = 0,
}) {
  h.vad.pushSpeech(speech);
  h.vad.pushSilence(silence);
  final nSamples = (speech + silence) * sileroWindow16k;
  h.session.feedAudio(Float32List(nSamples));
}

WordResult wordResult(RecitationSession s, int idx) =>
    s.currentAyah!.wordResults.firstWhere((w) => w.wordIdx == idx);

void main() {
  // Speech windows comfortably past minSpeechSamples (1600 / 512 ≈ 4).
  const speechWindows = 6;
  // Silence windows past the baseline silence window (8000 / 512 ≈ 16).
  const baselineSilenceWindows = 18;

  const baselineSilenceSamples = 8000; // 500 ms @ 16 kHz
  const stretchedSilenceSamples = 32000; // 2.0 s @ 16 kHz

  group('always advance (no locking)', () {
    test('a clean two-word recitation advances through every word and completes',
        () async {
      final h = makeHarness(
        {(1, 1): 'قَلَ رَبَ'},
        // Huge baseChunkS ⇒ process() never commits; only the boundary flush
        // does, so each phrase commits exactly one scripted string.
        AdaptiveConfig(baseChunkS: 1000, rightLookaheadS: 0),
      );
      await h.session.startAyah(sura: 1, ayah: 1);
      expect(h.session.wordSpanCount, 2);

      // Phrase 1: word 0, recited correctly.
      h.model.pushPhonemes('قَلَ');
      feed(h, speech: speechWindows, silence: baselineSilenceWindows);
      expect(wordResult(h.session, 0).status, WordStatus.correct);
      expect(h.session.currentAyah!.currentWordIdx, 1,
          reason: 'session should advance past word 0');
      expect(h.session.currentAyah!.status, AyahStatus.inProgress);

      // Phrase 2: word 1, recited correctly.
      h.model.pushPhonemes('رَبَ');
      feed(h, speech: speechWindows, silence: baselineSilenceWindows);
      expect(wordResult(h.session, 1).status, WordStatus.correct);
      expect(h.session.currentAyah!.status, AyahStatus.complete,
          reason: 'every word committed ⇒ ayah complete');
    });

    test('a mis-recited word commits a red result without ever locking the ayah',
        () async {
      final h = makeHarness(
        {(1, 1): 'قَلَ رَبَ'},
        AdaptiveConfig(baseChunkS: 1000, rightLookaheadS: 0),
      );
      await h.session.startAyah(sura: 1, ayah: 1);

      // Mis-recite word 0 ('مم' shares nothing with 'قَلَ' ⇒ PER ≥ 0.75).
      h.model.pushPhonemes('مم');
      feed(h, speech: speechWindows, silence: baselineSilenceWindows);

      // Red is preserved as a colour tier...
      expect(wordResult(h.session, 0).status, WordStatus.locked,
          reason: 'a severe error must still read as red');
      // ...but the session does NOT block: no locked ayah status.
      expect(h.session.currentAyah!.status, AyahStatus.inProgress);
      expect(h.session.currentAyah!.status, isNot(AyahStatus.lockedOnFirstWord));
      expect(h.session.currentAyah!.status, isNot(AyahStatus.locked));
    });
  });

  group('repetitions allowed', () {
    test('re-reciting an earlier word replaces it in place and bumps the count',
        () async {
      final h = makeHarness(
        {(1, 1): 'قَلَ رَبَ سَ'},
        AdaptiveConfig(baseChunkS: 1000, rightLookaheadS: 0),
      );
      await h.session.startAyah(sura: 1, ayah: 1);
      expect(h.session.wordSpanCount, 3);

      // Phrase 1: recite words 0 and 1 in one breath, advancing to word 2.
      h.model.pushPhonemes('قَلَرَبَ');
      feed(h, speech: speechWindows, silence: baselineSilenceWindows);
      expect(h.session.currentAyah!.currentWordIdx, 2);
      expect(wordResult(h.session, 0).nRepetitions, 1);

      // Phrase 2: go back and re-recite word 0 — classified as a repetition.
      h.model.pushPhonemes('قَلَ');
      feed(h, speech: speechWindows, silence: baselineSilenceWindows);

      final w0 = wordResult(h.session, 0);
      expect(w0.status, WordStatus.correct);
      expect(w0.nRepetitions, 2,
          reason: 'a repetition bumps the stored word\'s repetition count');
    });
  });

  group('Madd anticipation is retained (no lock snap-back)', () {
    test('a Madd word still stretches the VAD silence window', () async {
      // word 0 carries a 4-alif Madd run; word 1 is plain.
      final h = makeHarness(
        {(1, 1): 'قَاااا رَبَ'},
        AdaptiveConfig(baseChunkS: 1000, rightLookaheadS: 0),
      );
      await h.session.startAyah(sura: 1, ayah: 1);

      // Baseline before any feed.
      expect(h.gate.minSilenceSamples, baselineSilenceSamples);

      // The first feed runs _updateVadThreshold, which anticipates word 0's
      // Madd and stretches the silence window. With locking gone, nothing ever
      // snaps this back to baseline mid-word.
      feed(h, speech: speechWindows);
      expect(
        h.gate.minSilenceSamples,
        stretchedSilenceSamples,
        reason: 'Madd anticipation should stretch the VAD window to 2.0 s',
      );
    });
  });

  group('eager path holds a stuck word (no red cascade)', () {
    test('stopping at a word neither advances the pointer nor fabricates reds',
        () async {
      final liveHints = <WordResult>[];

      // Small baseChunkS ⇒ the streamer commits during process() (the EAGER
      // path), not only at the VAD flush. We feed speech ONLY (no silence) so
      // no phrase boundary ever fires — this isolates the eager path from the
      // boundary classifier. ~10 240 samples per feed (20 × 512) clears the
      // 8000-sample (0.5 s) commit milestone, so each feed commits one phrase.
      final h = makeHarness(
        {(1, 1): 'قَلَ رَبَ سَ مَ'},
        AdaptiveConfig(baseChunkS: 0.5, rightLookaheadS: 0),
      );
      h.session.onLiveWordFeedback = liveHints.add;
      await h.session.startAyah(sura: 1, ayah: 1);
      expect(h.session.wordSpanCount, 4);

      // Part 1: recite word 0 correctly. The eager path commits it (perfect
      // match) and advances to word 1.
      h.model.pushPhonemes('قَلَ');
      feed(h, speech: 20);
      expect(wordResult(h.session, 0).status, WordStatus.correct);
      expect(h.session.currentAyah!.currentWordIdx, 1);

      // Part 2: the reciter STOPS at word 1 — only ambient noise reaches the
      // mic, so the streamer commits garbage phonemes that share nothing with
      // the reference. BEFORE the fix the eager path marched forward, marking
      // words 1..3 red. The hold must now keep the pointer on word 1 and emit
      // no phantom results.
      h.model.pushPhonemes('سشصضطظ');
      feed(h, speech: 20);

      expect(
        h.session.currentAyah!.wordResults.where((w) => w.wordIdx >= 1),
        isEmpty,
        reason: 'a stuck word must not cascade red onto un-recited words',
      );
      expect(
        h.session.currentAyah!.currentWordIdx,
        1,
        reason: 'the pointer holds on the word being waited for',
      );
      expect(h.session.currentAyah!.status, AyahStatus.inProgress);

      // The held word still surfaces a provisional, non-committing live hint —
      // the same signal the UI uses to glow the word it is waiting for.
      expect(
        liveHints,
        isNotEmpty,
        reason: 'the word being waited on should surface a live hint',
      );
    });

    test('a clean go-back to an earlier word does NOT flash a red live hint',
        () async {
      // Counterpart to the stuck-word test above: when the reciter pauses and
      // resumes from an EARLIER word, the eager path (which only scans forward)
      // would otherwise score the re-recited audio as a garbage attempt on the
      // current word and flash it red until the next boundary. The eager
      // repetition back-check must recognise the clean go-back and suppress
      // that misleading hint.
      final liveHints = <WordResult>[];
      final h = makeHarness(
        {(1, 1): 'قَلَ رَبَ سَ'},
        AdaptiveConfig(baseChunkS: 0.5, rightLookaheadS: 0),
      );
      h.session.onLiveWordFeedback = liveHints.add;
      await h.session.startAyah(sura: 1, ayah: 1);

      // Recite words 0 and 1 correctly (each commits eagerly), advancing to
      // word 2.
      h.model.pushPhonemes('قَلَ');
      feed(h, speech: 20);
      h.model.pushPhonemes('رَبَ');
      feed(h, speech: 20);
      expect(h.session.currentAyah!.currentWordIdx, 2);

      // Isolate the go-back phase: drop any hints from the forward pass.
      liveHints.clear();

      // The reciter takes a breath and resumes from word 0 ('قَلَ'). The eager
      // path aligns this forward against word 2 ('سَ') — a bad score that would
      // fire a red hint — but the back-check sees it cleanly matches word 0.
      h.model.pushPhonemes('قَلَ');
      feed(h, speech: 20);

      expect(
        liveHints,
        isEmpty,
        reason: 'a clean go-back must not be flagged as an error on the '
            'current word',
      );
      // The eager path still cannot commit a repetition (it only scans
      // forward), so it holds: no phantom result past word 1, pointer steady.
      expect(
        h.session.currentAyah!.wordResults.where((w) => w.wordIdx >= 2),
        isEmpty,
        reason: 'the go-back must not commit a forward word',
      );
      expect(h.session.currentAyah!.currentWordIdx, 2);
    });

    test('a multi-word go-back during continuous recitation advances the '
        'pointer without waiting for a pause', () async {
      // The on-device breath-then-go-back: the reciter pauses before a word,
      // resumes a couple words EARLIER, and recites continuously (no silence).
      // The forward-only eager path head-of-line blocks on the expected word,
      // and no VAD boundary fires to run the repetition classifier — so the
      // pointer would freeze. _maybeClassifyGoBack recognises the clean
      // multi-word backward match and classifies NOW, following the reciter.
      final h = makeHarness(
        {(1, 1): 'قَلَ رَبَ سَ مَ'},
        AdaptiveConfig(baseChunkS: 0.5, rightLookaheadS: 0),
      );
      await h.session.startAyah(sura: 1, ayah: 1);

      // Recite words 0 and 1 (each commits eagerly), advancing to word 2.
      h.model.pushPhonemes('قَلَ');
      feed(h, speech: 20);
      h.model.pushPhonemes('رَبَ');
      feed(h, speech: 20);
      expect(h.session.currentAyah!.currentWordIdx, 2);

      // Go back to word 0 and re-recite 0,1,2 in one continuous breath (NO
      // silence ⇒ no VAD boundary). The phrase cleanly matches the earlier
      // words and overlaps the expected word 2.
      h.model.pushPhonemes('قَلَرَبَسَ');
      feed(h, speech: 20);

      // The go-back was classified immediately: words 0,1 replaced, word 2
      // committed, and the pointer advanced to 3 — no freeze, no boundary.
      expect(
        h.session.currentAyah!.currentWordIdx,
        3,
        reason: 'the pointer follows the reciter through the go-back',
      );
      expect(wordResult(h.session, 2).status, WordStatus.correct);
      expect(
        wordResult(h.session, 0).nRepetitions,
        2,
        reason: 're-reciting word 0 bumps its repetition count',
      );
    });
  });

  group('eager skip-ahead unblocks a head-of-line model miss', () {
    test('a garbled word with a cleanly-recited NEXT word commits red and '
        'advances instead of freezing', () async {
      // The on-device failure: the model garbles/drops one word (e.g. a reduced
      // connecting وَ with no CTC peak). The reciter has moved on, but the eager
      // path froze on the bad word for ~9s until a VAD boundary. With
      // skip-ahead, a clean LATER word is proof the reciter moved on, so the
      // garbled word commits red and the pointer advances immediately.
      // word 1 ('رَ') is a single chunk; word 2 ('سَ') is distinct. A
      // multi-chunk garbage run on word 1 over-counts (insertions cost 1.0
      // each ⇒ PER ≫ 0.75), unlike a same-length substitution which the
      // length-based chunk cost would score as free.
      final h = makeHarness(
        {(1, 1): 'قَلَ رَ سَ'},
        AdaptiveConfig(baseChunkS: 0.5, rightLookaheadS: 0),
      );
      await h.session.startAyah(sura: 1, ayah: 1);

      // Recite word 0 correctly (commits eagerly, advances to word 1).
      h.model.pushPhonemes('قَلَ');
      feed(h, speech: 20);
      expect(h.session.currentAyah!.currentWordIdx, 1);

      // The model garbles word 1 (4-chunk run 'مَمَمَمَ' vs the 1-chunk 'رَ' ⇒
      // 3 insertions ⇒ PER ≥ 0.75) but cleanly captures word 2 ('سَ').
      // Aligning from word 1 yields a non-last match: garbage on word 1, clean
      // on word 2.
      h.model.pushPhonemes('مَمَمَمَسَ');
      feed(h, speech: 20);

      // Word 1 is committed RED (not frozen on)...
      expect(
        wordResult(h.session, 1).status,
        WordStatus.locked,
        reason: 'the garbled word commits as a severe error',
      );
      // ...the clean next word is committed correct...
      expect(wordResult(h.session, 2).status, WordStatus.correct);
      // ...and the pointer advanced past both instead of freezing on word 1.
      expect(
        h.session.currentAyah!.currentWordIdx,
        3,
        reason: 'skip-ahead unblocks the head-of-line stall',
      );
    });

    test('a garbled word with NO clean next word still holds (no false skip)',
        () async {
      // Counter-case: pure noise with no cleanly-recited later word must NOT
      // trigger skip-ahead — otherwise a reciter who simply stops would have
      // un-recited words fabricated red (the cascade the hold prevents).
      final h = makeHarness(
        {(1, 1): 'قَلَ رَبَ سَ مَ'},
        AdaptiveConfig(baseChunkS: 0.5, rightLookaheadS: 0),
      );
      await h.session.startAyah(sura: 1, ayah: 1);

      h.model.pushPhonemes('قَلَ');
      feed(h, speech: 20);
      expect(h.session.currentAyah!.currentWordIdx, 1);

      // All-garbage: no later word aligns cleanly ⇒ movedPast is false ⇒ hold.
      h.model.pushPhonemes('سشصضطظ');
      feed(h, speech: 20);

      expect(
        h.session.currentAyah!.wordResults.where((w) => w.wordIdx >= 1),
        isEmpty,
        reason: 'no clean later word ⇒ no skip, no red cascade',
      );
      expect(h.session.currentAyah!.currentWordIdx, 1);
    });
  });
}
