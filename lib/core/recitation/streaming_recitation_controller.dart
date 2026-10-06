import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:quran_recitation_core/quran_recitation_core.dart';

import 'audio_recorder.dart';
import 'recitation_debug.dart';
import 'recitation_worker.dart';

/// Lifecycle phase of a live streaming recitation.
enum StreamingPhase {
  /// Nothing started yet.
  idle,

  /// Warming the model + loading the ayah reference.
  loading,

  /// Mic is open and audio is feeding the streamer.
  listening,

  /// Stopping: flushing the streamer and finalizing the ayah.
  finalizing,

  /// Finished — the per-ayah results are populated.
  finished,

  /// A user-actionable failure; see
  /// [StreamingRecitationController.errorMessage].
  error,
}

/// A single ayah on the page the user is reciting through, identified by its
/// surah + ayah number.
typedef AyahRef = ({int sura, int ayah});

/// Drives a live, on-device streaming recitation across a *page* of ayahs and
/// exposes the incremental per-ayah results to the UI as a [ChangeNotifier].
///
/// Pipeline: mic ([AudioRecorderService.startStream]) → [RecitationWorker].
/// The heavy `RecitationSession` + ONNX inference live in a worker isolate;
/// this controller only ships audio chunks in and maps the worker's
/// [RecitationEvent]s back onto observable UI state.
///
/// Unlike a single-ayah flow, the session is allowed to auto-advance from one
/// ayah to the next (the core `RecitationSession` preloads + advances within a
/// surah on its own). This controller mirrors that advance with an "active
/// ayah" pointer into [_pageAyahs] so each word event is attributed to the
/// right ayah, colours persist per ayah down the page, and recitation stops
/// once the last ayah of the page completes. Crossing a surah boundary mid-page
/// re-seeds the worker session (the core preloads only the same-surah
/// successor).
class StreamingRecitationController extends ChangeNotifier {
  StreamingRecitationController({
    AudioRecorderService? recorder,
    RecitationWorker? worker,
  })  : _recorder = recorder ?? AudioRecorderService(),
        _worker = worker ?? RecitationWorker();

  final AudioRecorderService _recorder;
  final RecitationWorker _worker;

  /// Invoked once, while listening, when the *last ayah of the page* finishes
  /// (the reciter stopped after its last word). The UI wires this to its own
  /// Stop handler so auto-stop goes through the same path as tapping the
  /// button. If left null, the controller falls back to [stop] directly.
  VoidCallback? onAyahFinished;

  StreamSubscription<Float32List>? _sub;
  StreamSubscription<RecitationEvent>? _eventSub;

  StreamingPhase _phase = StreamingPhase.idle;
  String _liveText = '';
  String? _errorMessage;
  bool _isElongating = false;
  bool _autoStopping = false;

  /// Ordered ayahs of the page being recited. Set by [start].
  List<AyahRef> _pageAyahs = const <AyahRef>[];

  /// Index into [_pageAyahs] of the ayah the session is currently scoring.
  /// Advances on [_onAyahComplete].
  int _activeAyahIndex = 0;

  /// Committed per-word results, keyed by `"sura:ayah"` then by `wordIdx`.
  /// Colours for finished ayahs persist here as the flow moves down the page.
  final Map<String, Map<int, WordResult>> _wordsByAyah =
      <String, Map<int, WordResult>>{};

  /// Finalized aggregate per ayah, keyed by `"sura:ayah"`.
  final Map<String, AyahResult> _ayahResults = <String, AyahResult>{};

  /// Ayah keys whose completion has already advanced the pointer — guards
  /// against the session firing `onAyahComplete` more than once per ayah
  /// (eager path, `finalizeAyah`, and `_applyNextAyah` can each fire it).
  final Set<String> _completedKeys = <String>{};

  /// Provisional live result for the word currently being recited (always the
  /// active ayah). Never overrides a committed result — see [wordsForAyah].
  WordResult? _liveWord;

  /// Monotonic token guarding the delayed "re-seed if stalled" check so an
  /// older pending check can't fire after a newer advance.
  int _reseedToken = 0;

  /// Wall clock since the current listen started; drives the `[timing-ui]`
  /// latency logs (see [kRecitationTimingLogs]). [_lastStreamUpdateMs] records
  /// when phonemes last grew, so a committed word can report how long after the
  /// phonemes it actually coloured.
  final Stopwatch _clock = Stopwatch();
  int _lastStreamUpdateMs = 0;

  static String _keyOf(int sura, int ayah) => '$sura:$ayah';

  StreamingPhase get phase => _phase;

  /// The streamer's running phoneme hypothesis.
  String get liveText => _liveText;

  /// Non-null only in [StreamingPhase.error].
  String? get errorMessage => _errorMessage;

  /// True while the streamer is holding for a Madd (elongation).
  bool get isElongating => _isElongating;

  /// The page's ordered ayahs (empty before [start]).
  List<AyahRef> get pageAyahs => _pageAyahs;

  /// The ayah the session is currently scoring, or null when idle / finished
  /// past the page.
  AyahRef? get activeAyah =>
      (_activeAyahIndex >= 0 && _activeAyahIndex < _pageAyahs.length)
          ? _pageAyahs[_activeAyahIndex]
          : null;

  bool _isActive(int sura, int ayah) {
    final a = activeAyah;
    return a != null && a.sura == sura && a.ayah == ayah;
  }

  /// Committed (and, for the active ayah, provisional) word results for
  /// `(sura, ayah)`, sorted by position. Drives the page's per-ayah colouring.
  List<WordResult> wordsForAyah(int sura, int ayah) {
    final byIdx = <int, WordResult>{};
    final committed = _wordsByAyah[_keyOf(sura, ayah)];
    if (committed != null) byIdx.addAll(committed);
    final live = _liveWord;
    if (live != null &&
        _isActive(sura, ayah) &&
        !byIdx.containsKey(live.wordIdx)) {
      byIdx[live.wordIdx] = live;
    }
    return byIdx.values.toList()..sort((a, b) => a.wordIdx - b.wordIdx);
  }

  /// The finalized aggregate for `(sura, ayah)`, or null if not yet scored.
  AyahResult? ayahResultFor(int sura, int ayah) =>
      _ayahResults[_keyOf(sura, ayah)];

  /// Every committed word across the whole page (used for the summary).
  Iterable<WordResult> get allWords =>
      _wordsByAyah.values.expand((m) => m.values);

  /// Page-level accuracy = mean of `1 - overallPer` across scored ayahs.
  double get pageAccuracy {
    if (_ayahResults.isEmpty) return 0;
    final sum = _ayahResults.values
        .fold<double>(0, (acc, r) => acc + (1.0 - r.overallPer));
    return (sum / _ayahResults.length).clamp(0.0, 1.0);
  }

  /// Index of the word the active ayah is currently waiting for — the lowest
  /// word not yet committed. While a word is being recited but held (live
  /// hint), its index pins the expectation. Drives the "glowing" highlight.
  int get currentWordIdx {
    final active = activeAyah;
    if (active == null) return 0;
    final committed = _wordsByAyah[_keyOf(active.sura, active.ayah)];
    final live = _liveWord;
    if (live != null && (committed == null || !committed.containsKey(live.wordIdx))) {
      return live.wordIdx;
    }
    var i = 0;
    while (committed != null && committed.containsKey(i)) {
      i++;
    }
    return i;
  }

  /// The word `(sura, ayah)` is waiting on, or -1 when it isn't the active
  /// ayah / we aren't listening (nothing to anticipate).
  int waitingWordIdxFor(int sura, int ayah) {
    if (_phase != StreamingPhase.listening || !_isActive(sura, ayah)) return -1;
    return currentWordIdx;
  }

  bool get isListening => _phase == StreamingPhase.listening;
  bool get isBusy =>
      _phase == StreamingPhase.loading || _phase == StreamingPhase.finalizing;

  /// Loads the model + reference for `(startSura, startAyah)`, opens the mic,
  /// and begins streaming through [pageAyahs] (the ordered ayahs displayed on
  /// the page; recitation flows from the start ayah to the page's last ayah).
  /// Safe to call only from [StreamingPhase.idle], [StreamingPhase.finished],
  /// or [StreamingPhase.error].
  Future<void> start({
    required int startSura,
    required int startAyah,
    required List<AyahRef> pageAyahs,
  }) async {
    if (_phase == StreamingPhase.loading ||
        _phase == StreamingPhase.listening ||
        _phase == StreamingPhase.finalizing) {
      return;
    }

    final ayahs = pageAyahs.isEmpty
        ? <AyahRef>[(sura: startSura, ayah: startAyah)]
        : List<AyahRef>.from(pageAyahs);
    var idx = ayahs.indexWhere(
      (a) => a.sura == startSura && a.ayah == startAyah,
    );
    if (idx < 0) {
      // Start ayah isn't part of the page list — recite just it.
      ayahs
        ..clear()
        ..add((sura: startSura, ayah: startAyah));
      idx = 0;
    }

    _pageAyahs = ayahs;
    _activeAyahIndex = idx;
    _liveText = '';
    _isElongating = false;
    _autoStopping = false;
    _errorMessage = null;
    _wordsByAyah.clear();
    _ayahResults.clear();
    _completedKeys.clear();
    _liveWord = null;
    _lastStreamUpdateMs = 0;
    _clock
      ..reset()
      ..start();
    _setPhase(StreamingPhase.loading);

    try {
      if (!await _recorder.hasPermission()) {
        _fail('Microphone permission is required for live recitation.');
        return;
      }

      // Spawn + load the worker isolate (idempotent) and listen for its events.
      await _worker.load();
      _eventSub ??= _worker.events.listen(_onWorkerEvent);

      final spanCount =
          await _worker.startAyah(sura: startSura, ayah: startAyah);
      debugPrint(
        '[stream] BUILD=worker startAyah $startSura:$startAyah spans=$spanCount',
      );

      final stream = await _recorder.startStream();
      _sub = stream.listen(
        _onAudioChunk,
        onError: (Object e) => _fail('Audio stream error: $e'),
        cancelOnError: true,
      );
      _setPhase(StreamingPhase.listening);
    } catch (e) {
      _fail('Could not start live recitation: $e');
    }
  }

  /// Stops the mic, flushes the worker's streamer, and finalizes the active
  /// ayah. No-op unless currently listening.
  Future<void> stop() async {
    if (_phase != StreamingPhase.listening) return;
    _setPhase(StreamingPhase.finalizing);
    try {
      await _sub?.cancel();
      _sub = null;
      await _recorder.stopStream();
      // The worker fires residual word/ayah events before replying; those land
      // on _onWorkerEvent. This reply is the authoritative aggregate.
      final result = await _worker.finalize();
      if (result != null) {
        _ayahResults[_keyOf(result.sura, result.ayah)] = result;
        _mergeWords(result.sura, result.ayah, result.wordResults);
      }
      _liveWord = null;
      _isElongating = false;
      _setPhase(StreamingPhase.finished);
    } catch (e) {
      _fail('Could not finalize recitation: $e');
    }
  }

  void _onAudioChunk(Float32List chunk) {
    if (_phase != StreamingPhase.listening) return;
    // Cheap port send — inference happens in the worker isolate.
    _worker.feedAudio(chunk);
  }

  void _onWorkerEvent(RecitationEvent event) {
    switch (event) {
      case RecitationStreamUpdate(:final fullText):
        _liveText = fullText;
        if (kRecitationTimingLogs) {
          _lastStreamUpdateMs = _clock.elapsedMilliseconds;
          // Log the FULL heard text (what the UI's "Heard" box shows) so a word
          // whose phonemes are clearly present but mis-scored can be diffed
          // against its reference from the logs alone.
          debugPrint('[timing-ui] t=${_lastStreamUpdateMs}ms STREAM '
              'len=${fullText.length} heard="$fullText"');
        }
        notifyListeners();
      case RecitationWord(:final word):
        if (kRecitationTimingLogs) {
          final now = _clock.elapsedMilliseconds;
          debugPrint('[timing-ui] t=${now}ms WORD idx=${word.wordIdx} '
              'status=${word.status.name} per=${word.per.toStringAsFixed(2)} '
              'sinceLastPhoneme=${now - _lastStreamUpdateMs}ms');
        }
        _onWordComplete(word);
      case RecitationLiveWord(:final word):
        if (kRecitationTimingLogs) {
          debugPrint('[timing-ui] t=${_clock.elapsedMilliseconds}ms LIVE '
              'idx=${word.wordIdx} status=${word.status.name}');
        }
        _onLiveWordFeedback(word);
      case RecitationAyahComplete(:final result):
        _onAyahComplete(result);
      case RecitationElongating(:final isElongating):
        if (_isElongating != isElongating) {
          _isElongating = isElongating;
          debugPrint('[stream] elongating=$_isElongating');
          notifyListeners();
        }
      case RecitationError(:final message):
        _fail(message);
    }
  }

  void _onWordComplete(WordResult wr) {
    final active = activeAyah;
    if (active == null) return;
    final map = _wordsByAyah.putIfAbsent(
      _keyOf(active.sura, active.ayah),
      () => <int, WordResult>{},
    );
    final isReplace = map.containsKey(wr.wordIdx);
    debugPrint(
      '[stream] WORD ${active.sura}:${active.ayah}#${wr.wordIdx} '
      'per=${wr.per.toStringAsFixed(2)} status=${wr.status}',
    );
    if (kRecitationCorrectionLogs) {
      _logCorrection(wr, isReplace ? 'REPLACE' : 'COMMIT');
    }
    map[wr.wordIdx] = wr;
    // A committed result supersedes any live hint for this word (or an earlier
    // one the reciter has now moved past).
    final live = _liveWord;
    if (live != null && wr.wordIdx >= live.wordIdx) {
      _liveWord = null;
    }
    notifyListeners();
  }

  /// Provisional, non-committed result for the in-progress word of the active
  /// ayah. Superseded the moment a committed result for it arrives.
  void _onLiveWordFeedback(WordResult wr) {
    final active = activeAyah;
    if (active == null) return;
    final committed = _wordsByAyah[_keyOf(active.sura, active.ayah)];
    if (committed != null && committed.containsKey(wr.wordIdx)) return;
    final prev = _liveWord;
    if (prev != null &&
        prev.wordIdx == wr.wordIdx &&
        prev.status == wr.status &&
        prev.per == wr.per) {
      return; // nothing visibly changed; skip the rebuild
    }
    if (kRecitationCorrectionLogs) _logCorrection(wr, 'LIVE');
    _liveWord = wr;
    notifyListeners();
  }

  /// Dumps the full error-correction breakdown for [wr] under [tag] — the exact
  /// data the correction drawer renders — so a wrong correction is visible in
  /// logcat before the UI is trusted. Gated by [kRecitationCorrectionLogs].
  void _logCorrection(WordResult wr, String tag) {
    String ruleStr(TajweedRuleRef r) {
      final hasLen = r.expectedLen != null || r.actualLen != null;
      final len = hasLen ? '(exp=${r.expectedLen ?? '?'},act=${r.actualLen ?? '?'})' : '';
      return '${r.nameEn}$len';
    }

    debugPrint('[correction] $tag idx=${wr.wordIdx} "${wr.uthmaniWord}" '
        'status=${wr.status.name} per=${wr.per.toStringAsFixed(3)} '
        'reps=${wr.nRepetitions} conf=${wr.confidence.toStringAsFixed(2)}');
    debugPrint('[correction]   ref="${wr.refPhonemes}" hyp="${wr.hypPhonemes}"');

    if (wr.phonemeErrors.isEmpty) {
      debugPrint('[correction]   phonemeErrors: none');
    } else {
      debugPrint('[correction]   phonemeErrors(${wr.phonemeErrors.length}):');
      for (var i = 0; i < wr.phonemeErrors.length; i++) {
        final e = wr.phonemeErrors[i];
        final rules = <String>[
          if (e.refTajweedRules.isNotEmpty)
            'ref=${e.refTajweedRules.map(ruleStr).join('|')}',
          if (e.missingTajweedRules.isNotEmpty)
            'missing=${e.missingTajweedRules.map(ruleStr).join('|')}',
          if (e.insertedTajweedRules.isNotEmpty)
            'inserted=${e.insertedTajweedRules.map(ruleStr).join('|')}',
          if (e.replacedTajweedRules.isNotEmpty)
            'replaced=${e.replacedTajweedRules.map(ruleStr).join('|')}',
        ];
        debugPrint('[correction]     #$i ${e.speechErrorType.name}/'
            '${e.errorType.name} exp="${e.expectedPhonemes}" '
            'got="${e.predictedPhonemes}" uth=${e.uthmaniSpan} ph=${e.phonemeSpan}'
            '${rules.isEmpty ? '' : ' ${rules.join(' ')}'}');
      }
    }

    if (wr.sifatDiffs.isEmpty) {
      debugPrint('[correction]   sifatDiffs: none');
    } else {
      debugPrint('[correction]   sifatDiffs(${wr.sifatDiffs.length}):');
      for (final d in wr.sifatDiffs) {
        debugPrint('[correction]     chunk=${d.chunkIdx} "${d.phonemeGroup}" '
            '${d.attribute}: exp=${d.expected ?? '—'} got=${d.predicted ?? '—'}');
      }
    }
  }

  void _onAyahComplete(AyahResult result) {
    final key = _keyOf(result.sura, result.ayah);
    // Always keep the latest aggregate + words (idempotent merge).
    _ayahResults[key] = result;
    _mergeWords(result.sura, result.ayah, result.wordResults);

    // Advance the pointer at most once per ayah.
    if (_completedKeys.contains(key)) {
      notifyListeners();
      return;
    }
    _completedKeys.add(key);

    debugPrint(
      '[stream] AYAH COMPLETE ${result.sura}:${result.ayah} '
      'status=${result.status} idx=$_activeAyahIndex/${_pageAyahs.length - 1}',
    );

    final isLastOfPage = _activeAyahIndex >= _pageAyahs.length - 1;
    if (isLastOfPage) {
      _liveWord = null;
      notifyListeners();
      _scheduleAutoStop();
      return;
    }

    // Advance to the next ayah on the page.
    final completed = _pageAyahs[_activeAyahIndex];
    _activeAyahIndex++;
    _liveWord = null;
    final next = _pageAyahs[_activeAyahIndex];
    notifyListeners();

    // The core session goes deaf the instant an ayah is marked `complete`
    // (feedAudio early-returns), so its native auto-advance only works when the
    // reciter flows into the next ayah within one continuous phrase. The
    // moment they pause, the session stops listening. To keep going we re-seed
    // a fresh worker session for the next ayah — making every ayah behave like
    // the first one.
    //
    // Across a surah boundary the core can't preload the successor at all, so
    // re-seed immediately. Within a surah, give native auto-advance a brief
    // chance first (continuous reciters) and only re-seed if the next ayah is
    // still silent — see [_scheduleReseed].
    if (next.sura != completed.sura) {
      scheduleMicrotask(() => _reseed(next.sura, next.ayah, _activeAyahIndex));
    } else {
      _scheduleReseed(next, _activeAyahIndex);
    }
  }

  /// After advancing within a surah, wait briefly: if native auto-advance has
  /// already started feeding the next ayah (a continuous reciter), do nothing;
  /// otherwise the session has gone deaf, so re-seed it.
  void _scheduleReseed(AyahRef next, int forIndex) {
    final token = ++_reseedToken;
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      if (token != _reseedToken) return; // a newer advance superseded us
      if (_phase != StreamingPhase.listening) return;
      if (_activeAyahIndex != forIndex) return;
      final committed = _wordsByAyah[_keyOf(next.sura, next.ayah)];
      if (committed != null && committed.isNotEmpty) return; // native advance OK
      unawaited(_reseed(next.sura, next.ayah, forIndex));
    });
  }

  /// Tears down and rebuilds the worker session for `(sura, ayah)` without
  /// closing the mic. Used to continue into the next ayah after a pause (and at
  /// surah boundaries the core can't cross on its own).
  Future<void> _reseed(int sura, int ayah, int forIndex) async {
    if (_phase != StreamingPhase.listening) return;
    if (_activeAyahIndex != forIndex) return;
    try {
      debugPrint('[stream] RESEED worker for $sura:$ayah');
      await _worker.startAyah(sura: sura, ayah: ayah);
    } catch (e) {
      _fail('Could not continue into $sura:$ayah: $e');
    }
  }

  void _scheduleAutoStop() {
    // The worker fires onAyahComplete once the final word lands (via the
    // silence timeout). Ask the UI to press its own Stop button rather than
    // finalizing silently, so the control visibly toggles. [stop] guards on
    // phase, so a second onAyahComplete from finalize() won't retrigger this.
    if (_phase == StreamingPhase.listening && !_autoStopping) {
      _autoStopping = true;
      scheduleMicrotask(() {
        _autoStopping = false;
        if (_phase != StreamingPhase.listening) return;
        debugPrint('[stream] AUTO-STOP -> pressing UI stop');
        final cb = onAyahFinished;
        if (cb != null) {
          cb();
        } else {
          unawaited(stop());
        }
      });
    }
  }

  void _mergeWords(int sura, int ayah, List<WordResult> results) {
    final map = _wordsByAyah.putIfAbsent(
      _keyOf(sura, ayah),
      () => <int, WordResult>{},
    );
    for (final w in results) {
      map[w.wordIdx] = w;
    }
  }

  void _setPhase(StreamingPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  void _fail(String message) {
    _errorMessage = message;
    _phase = StreamingPhase.error;
    _isElongating = false;
    unawaited(_sub?.cancel());
    _sub = null;
    unawaited(_recorder.stopStream().catchError((_) {}));
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _eventSub?.cancel();
    _recorder.dispose();
    unawaited(_worker.dispose());
    super.dispose();
  }
}
