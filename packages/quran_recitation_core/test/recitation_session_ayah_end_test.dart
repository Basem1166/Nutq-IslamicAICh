/// Guards the ayah-end silence cap ([SessionConfig.ayahEndSilenceMs]).
///
/// Ayah endings almost always carry a madd, so Madd anticipation used to hold
/// the VAD silence window at 2.0–2.5 s for the final word — the phrase
/// boundary that completes the ayah (and moves recitation on to the next one)
/// only fired that long after the reciter stopped. Once the last word has been
/// fully said, the window is capped; a madd word mid-ayah keeps the stretch.
///
/// Uses the scripted fakes from `test/support`, in the eager regime (small
/// `baseChunkS`) so the streamer decodes phonemes during speech, before the
/// silence — the real-world waqf case. The assertions are on the VAD phrase
/// boundary itself (what the cap controls): the scripted model emits each
/// string only once, so its re-decode at the boundary isn't representative of
/// the final scoring.
library;

import 'dart:typed_data';

import 'package:quran_recitation_core/quran_recitation_core.dart';
import 'package:test/test.dart';

import 'support/fake_recitation_model.dart';
import 'support/fake_reference_loader.dart';
import 'support/scripted_vad_backend.dart';

/// [VadGate] that counts the phrase boundaries it emits.
class _RecordingVadGate extends VadGate {
  _RecordingVadGate({required super.backend}) : super(energySpeechFloor: 0.0);

  int boundaries = 0;

  @override
  List<VadEvent> process(Float32List audioChunk) {
    final events = super.process(audioChunk);
    boundaries +=
        events.where((e) => e.type == VadEventType.phraseBoundary).length;
    return events;
  }
}

typedef Harness = ({
  RecitationSession session,
  ScriptedRecitationModel model,
  ScriptedVadBackend vad,
  _RecordingVadGate gate,
});

Harness makeHarness(Map<(int, int), String> texts) {
  final model = ScriptedRecitationModel();
  final streamer = AdaptiveStreamingMuaalem(
    model: model,
    cfg: AdaptiveConfig(baseChunkS: 0.5, rightLookaheadS: 0),
  );
  final vadBackend = ScriptedVadBackend();
  final gate = _RecordingVadGate(backend: vadBackend);
  final session = RecitationSession(
    streamer: streamer,
    referenceLoader: FakeReferenceLoader(texts),
    vadGate: gate,
    sessionConfig: const SessionConfig(vadEnabled: true),
  );
  return (session: session, model: model, vad: vadBackend, gate: gate);
}

void feed(Harness h, {int speech = 0, int silence = 0}) {
  h.vad.pushSpeech(speech);
  h.vad.pushSilence(silence);
  h.session.feedAudio(Float32List((speech + silence) * sileroWindow16k));
}

void main() {
  // ~768 ms of silence: past the 700 ms cap, well short of the 2.0 s stretch.
  const shortPauseWindows = 24;
  // ~1.6 s of speech: Madd anticipation widens the streamer chunk to 1.5 s,
  // so each feed must clear that for the streamer to decode it.
  const speechWindows = 50;

  test('a short pause after the final madd word ends the phrase', () async {
    // The final word has 7 phoneme chunks ending in a madd. It's recited with
    // one slip (PER 1/7 ≈ 0.14): too imperfect for the instant tentative
    // commit (≤ 0.05) but fully said (≤ eagerEmissionPer 0.20) — the case
    // that used to wait out the 2.0 s stretch.
    final h = makeHarness({(1, 1): 'قَلَ قَلَبَرَدَسَمَاااا'});
    await h.session.startAyah(sura: 1, ayah: 1);

    // The streamer commits each window one feed later, so word 0 lands while
    // the final word is being recited (into the uncommitted tail).
    h.model.pushPhonemes('قَلَ');
    feed(h, speech: speechWindows);
    h.model.pushPhonemes('قَلَبَرَدَصَمَاااا');
    feed(h, speech: speechWindows);
    expect(h.session.currentAyah!.currentWordIdx, 1);
    expect(h.gate.boundaries, 0);

    feed(h, silence: shortPauseWindows);
    expect(
      h.gate.boundaries,
      1,
      reason: 'the ayah-end cap should end the phrase after ~700 ms',
    );
  });

  test('a madd word mid-ayah keeps the stretched window', () async {
    final h = makeHarness({(1, 1): 'قَاااا رَبَ'});
    await h.session.startAyah(sura: 1, ayah: 1);

    h.model.pushPhonemes('قَاااا');
    feed(h, speech: speechWindows);
    feed(h, silence: shortPauseWindows);

    expect(h.gate.minSilenceSamples, 32000); // 2.0 s @ 16 kHz
    expect(h.gate.boundaries, 0);
  });
}
