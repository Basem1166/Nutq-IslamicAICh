import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:quran_recitation_core/quran_recitation_core.dart';

import 'ctc_decoder.dart';
import 'feature_extractor.dart';
import 'mualem_model.dart';
import 'phonetizer_reference_loader.dart';
import 'recitation_debug.dart';
import 'recitation_model_adapter.dart';
import 'silero_vad_backend.dart';

/// Off-UI-isolate host for the live recitation pipeline.
///
/// The heavy synchronous work — Mualem ONNX inference, Silero VAD, CTC decode
/// and the whole [RecitationSession] — used to run inline on the UI isolate as
/// each audio chunk arrived, which starved the frame pump ("Skipped N frames").
/// This moves all of it into a long-lived worker isolate: the UI isolate only
/// ships audio in (cheap `SendPort.send`) and receives [RecitationEvent]s out.
///
/// What stays on the root isolate
/// ──────────────────────────────
/// Asset/platform-bound work cannot run in a spawned isolate:
///   - The ONNX models + vocab are read as bytes here and transferred in once
///     (the worker rebuilds the ORT sessions from those bytes).
///   - Ayah references come from the phonetizer (`MethodChannel`) + the bundled
///     Quran JSON (`rootBundle`), both root-isolate-only. [startAyah] resolves
///     the target ayah and its successor here and ships both into the worker,
///     so the worker never needs a platform binding.
///
/// The worker itself is pure compute + ONNX FFI, which was validated to run
/// off the UI isolate before this was written.
class RecitationWorker {
  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  final StreamController<RecitationEvent> _events =
      StreamController<RecitationEvent>.broadcast();

  Completer<void>? _ready;
  Completer<void>? _loaded;
  Completer<int>? _started;
  Completer<AyahResult?>? _finalized;
  bool _disposed = false;

  /// Live events from the worker (stream updates, word/ayah results, the
  /// elongation flag, and errors). Lifecycle replies (loaded/started/finalized)
  /// are consumed internally by the awaitable methods, not surfaced here.
  Stream<RecitationEvent> get events => _events.stream;

  /// True once [load] has completed the model handoff.
  bool get isLoaded => _loaded?.isCompleted ?? false;

  Future<void> _ensureSpawned() async {
    if (_toWorker != null) return;
    final ready = _ready = Completer<void>();
    final rp = _fromWorker = ReceivePort();
    rp.listen(_onWorkerMessage);
    _isolate = await Isolate.spawn(_recitationWorkerMain, rp.sendPort);
    await ready.future;
  }

  /// Spawns the worker (if needed), reads the model/vocab assets on the root
  /// isolate, and transfers them in. Completes when the worker has rebuilt all
  /// three ORT/decoder objects. Idempotent.
  Future<void> load() async {
    await _ensureSpawned();
    final existing = _loaded;
    if (existing != null) return existing.future;
    final loaded = _loaded = Completer<void>();

    final mualem = await rootBundle.load(MualemModel.assetPath);
    final silero = await rootBundle.load(SileroVadBackend.assetPath);
    final vocab = await rootBundle.loadString(CtcDecoder.vocabAsset);

    _toWorker!.send(<dynamic>[
      _kInit,
      TransferableTypedData.fromList(<TypedData>[
        mualem.buffer.asUint8List(mualem.offsetInBytes, mualem.lengthInBytes),
      ]),
      TransferableTypedData.fromList(<TypedData>[
        silero.buffer.asUint8List(silero.offsetInBytes, silero.lengthInBytes),
      ]),
      vocab,
    ]);
    return loaded.future;
  }

  /// Resolves the reference for `(sura, ayah)` and its successor on the root
  /// isolate, ships both into the worker, and starts a fresh session there.
  /// Completes with the word-span count once the worker's session is ready.
  Future<int> startAyah({required int sura, required int ayah}) async {
    if (_toWorker == null) {
      throw StateError('RecitationWorker.load() must complete before startAyah');
    }
    final started = _started = Completer<int>();

    const loader = PhonetizerReferenceLoader();
    final target = await loader.load(sura: sura, ayah: ayah);
    AyahReference? next;
    try {
      next = await loader.load(sura: sura, ayah: ayah + 1);
    } catch (_) {
      // Last ayah of the sura, or unavailable — the session treats a missing
      // successor as "no next ayah" (auto-advance becomes a no-op).
      next = null;
    }

    _toWorker!.send(<dynamic>[_kStartAyah, sura, ayah, target, next]);
    return started.future;
  }

  /// Ships one chunk of float32 mono audio to the worker. Fire-and-forget — the
  /// worker runs inference and emits [RecitationEvent]s; this only does a cheap
  /// port send, so the UI isolate never blocks on inference.
  void feedAudio(Float32List chunk) {
    final port = _toWorker;
    if (port == null) return;
    port.send(<dynamic>[
      _kAudio,
      TransferableTypedData.fromList(<TypedData>[chunk]),
      // Send-time stamp (µs since epoch). The worker subtracts this from its
      // own clock to measure how long the chunk waited in the queue — a direct
      // read on backlog. Used only when [kRecitationTimingLogs] is on.
      DateTime.now().microsecondsSinceEpoch,
    ]);
  }

  /// Flushes and finalizes the active ayah in the worker. Word/ayah events for
  /// the residue arrive first on [events]; this completes with the authoritative
  /// [AyahResult] (or null if there was no active session).
  Future<AyahResult?> finalize() {
    final port = _toWorker;
    if (port == null) return Future<AyahResult?>.value();
    final fin = _finalized = Completer<AyahResult?>();
    port.send(<dynamic>[_kStop]);
    return fin.future;
  }

  /// Releases the worker's ORT sessions and tears down the isolate.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _toWorker?.send(<dynamic>[_kDispose]);
    // Grace window so the worker can release native ORT sessions before we
    // kill it; the dispose handler runs synchronously, so this is ample.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _toWorker = null;
    _fromWorker?.close();
    _fromWorker = null;
    if (!_events.isClosed) await _events.close();
  }

  void _onWorkerMessage(dynamic msg) {
    final list = msg as List<dynamic>;
    switch (list[0] as int) {
      case _kReady:
        _toWorker = list[1] as SendPort;
        _ready?.complete();
      case _kLoaded:
        _loaded?.complete();
      case _kLoadError:
        _loaded?.completeError(StateError(list[1] as String));
      case _kStarted:
        _started?.complete(list[1] as int);
      case _kStartError:
        _started?.completeError(StateError(list[1] as String));
      case _kStreamUpdate:
        _emit(RecitationStreamUpdate(list[1] as String));
      case _kWord:
        _emit(RecitationWord(list[1] as WordResult));
      case _kLiveWord:
        _emit(RecitationLiveWord(list[1] as WordResult));
      case _kAyahComplete:
        _emit(RecitationAyahComplete(list[1] as AyahResult));
      case _kElongating:
        _emit(RecitationElongating(list[1] as bool));
      case _kFinalized:
        _finalized?.complete(list[1] as AyahResult?);
      case _kError:
        _emit(RecitationError(list[1] as String));
    }
  }

  void _emit(RecitationEvent e) {
    if (!_events.isClosed) _events.add(e);
  }
}

// ─────────────────────────────────────────────────────────────────────────
//  Public events (UI ← worker)
// ─────────────────────────────────────────────────────────────────────────

/// A live event from the worker, consumed by the streaming controller.
sealed class RecitationEvent {
  const RecitationEvent();
}

/// The streamer's running phoneme hypothesis grew.
class RecitationStreamUpdate extends RecitationEvent {
  const RecitationStreamUpdate(this.fullText);
  final String fullText;
}

/// A committed per-word result.
class RecitationWord extends RecitationEvent {
  const RecitationWord(this.word);
  final WordResult word;
}

/// A provisional (non-committed) per-word hint for live tinting.
class RecitationLiveWord extends RecitationEvent {
  const RecitationLiveWord(this.word);
  final WordResult word;
}

/// The active ayah reached a terminal status mid-stream.
class RecitationAyahComplete extends RecitationEvent {
  const RecitationAyahComplete(this.result);
  final AyahResult result;
}

/// The streamer's Madd-elongation hold flag changed.
class RecitationElongating extends RecitationEvent {
  const RecitationElongating(this.isElongating);
  final bool isElongating;
}

/// A user-actionable failure raised inside the worker.
class RecitationError extends RecitationEvent {
  const RecitationError(this.message);
  final String message;
}

// ─────────────────────────────────────────────────────────────────────────
//  Wire protocol (private — list tuples keyed by an int tag)
// ─────────────────────────────────────────────────────────────────────────

// UI → worker
const int _kInit = 0;
const int _kStartAyah = 1;
const int _kAudio = 2;
const int _kStop = 3;
const int _kDispose = 4;

// worker → UI
const int _kReady = 100;
const int _kLoaded = 101;
const int _kLoadError = 102;
const int _kStarted = 103;
const int _kStartError = 104;
const int _kStreamUpdate = 105;
const int _kWord = 106;
const int _kLiveWord = 107;
const int _kAyahComplete = 108;
const int _kElongating = 109;
const int _kFinalized = 110;
const int _kError = 111;

// ─────────────────────────────────────────────────────────────────────────
//  Worker isolate
// ─────────────────────────────────────────────────────────────────────────

void _recitationWorkerMain(SendPort toClient) {
  final host = _WorkerHost(toClient);
  final commandPort = ReceivePort();
  host._commandPort = commandPort;
  commandPort.listen(host.handle);
  toClient.send(<dynamic>[_kReady, commandPort.sendPort]);
}

/// Owns the loaded models and the active session inside the worker isolate.
class _WorkerHost {
  _WorkerHost(this._toClient);

  final SendPort _toClient;
  late final ReceivePort _commandPort;

  final MualemModel _model = MualemModel();
  final MualemFeatureExtractor _extractor = MualemFeatureExtractor();
  SileroVadBackend? _vad;
  CtcDecoder? _decoder;

  AdaptiveStreamingMuaalem? _streamer;
  RecitationSession? _session;
  bool _lastElongating = false;

  /// Running Σ(inference − audio) deficit for `[timing-worker]`, floored at 0.
  /// Reset per ayah. Only mutated when [kRecitationTimingLogs] is on.
  double _cumDeficitMs = 0.0;

  void handle(dynamic msg) {
    final list = msg as List<dynamic>;
    switch (list[0] as int) {
      case _kInit:
        _init(list);
      case _kStartAyah:
        unawaited(_startAyah(list));
      case _kAudio:
        _audio(list);
      case _kStop:
        _stop();
      case _kDispose:
        _dispose();
    }
  }

  void _init(List<dynamic> list) {
    try {
      final mualem = (list[1] as TransferableTypedData).materialize();
      final silero = (list[2] as TransferableTypedData).materialize();
      final vocabJson = list[3] as String;
      _model.loadFromBytes(mualem.asUint8List());
      _vad = SileroVadBackend.fromBytes(silero.asUint8List());
      _decoder = CtcDecoder.fromVocabJson(vocabJson);
      _toClient.send(<dynamic>[_kLoaded]);
    } catch (e, st) {
      _toClient.send(<dynamic>[_kLoadError, 'Worker load failed: $e\n$st']);
    }
  }

  Future<void> _startAyah(List<dynamic> list) async {
    try {
      final sura = list[1] as int;
      final ayah = list[2] as int;
      final target = list[3] as AyahReference;
      final next = list[4] as AyahReference?;

      final cache = <String, AyahReference>{_refKey(sura, ayah): target};
      if (next != null) {
        cache[_refKey(next.sura, next.ayah)] = next;
      }

      final adapter = RecitationModelAdapter(
        model: _model,
        decoder: _decoder!,
        extractor: _extractor,
      );
      final streamer =
          AdaptiveStreamingMuaalem(model: adapter, cfg: AdaptiveConfig());
      final session = RecitationSession(
        streamer: streamer,
        referenceLoader: _CachedReferenceLoader(cache),
        vadGate: VadGate(backend: _vad!, energySpeechFloor: 0.0),
        sessionConfig: const SessionConfig(vadEnabled: true),
        onStreamUpdate: (t) => _toClient.send(<dynamic>[_kStreamUpdate, t]),
        onWordComplete: (w) => _toClient.send(<dynamic>[_kWord, w]),
        onAyahComplete: (a) => _toClient.send(<dynamic>[_kAyahComplete, a]),
        onLiveWordFeedback: (w) => _toClient.send(<dynamic>[_kLiveWord, w]),
      );
      _streamer = streamer;
      _session = session;
      _lastElongating = false;
      _cumDeficitMs = 0.0;

      await session.startAyah(sura: sura, ayah: ayah);
      _toClient.send(<dynamic>[_kStarted, session.wordSpanCount]);
    } catch (e, st) {
      _toClient.send(<dynamic>[_kStartError, 'startAyah failed: $e\n$st']);
    }
  }

  void _audio(List<dynamic> list) {
    final session = _session;
    if (session == null) return;
    final chunk = (list[1] as TransferableTypedData).materialize().asFloat32List();
    try {
      if (kRecitationTimingLogs) {
        _timedFeed(session, chunk, list[2] as int);
      } else {
        session.feedAudio(chunk);
      }
      final streamer = _streamer;
      if (streamer != null && streamer.isElongating != _lastElongating) {
        _lastElongating = streamer.isElongating;
        _toClient.send(<dynamic>[_kElongating, _lastElongating]);
      }
    } catch (e, st) {
      _toClient.send(<dynamic>[_kError, 'Inference failed: $e\n$st']);
    }
  }

  /// Runs one `feedAudio` wrapped in timing instrumentation (gated by
  /// [kRecitationTimingLogs]). Measures the queue wait (UI send → worker
  /// process), the inference wall time, and a running realtime deficit, so a
  /// worker that can't keep up with realtime audio shows up as a growing
  /// `queue`/`backlog` in logcat rather than a vague "it feels laggy".
  void _timedFeed(RecitationSession session, Float32List chunk, int sentUs) {
    final queueMs = (DateTime.now().microsecondsSinceEpoch - sentUs) / 1000.0;
    final sw = Stopwatch()..start();
    session.feedAudio(chunk);
    sw.stop();
    final procMs = sw.elapsedMicroseconds / 1000.0;
    final audioMs = chunk.length * 1000.0 / 16000.0;
    _cumDeficitMs += procMs - audioMs;
    // The real queue can't bank "ahead-of-realtime" credit below empty, so the
    // modelled backlog floors at 0.
    if (_cumDeficitMs < 0) _cumDeficitMs = 0.0;
    final realtimeX = audioMs > 0 ? procMs / audioMs : 0.0;
    // ignore: avoid_print
    print('[timing-worker] audio=${audioMs.toStringAsFixed(0)}ms '
        'proc=${procMs.toStringAsFixed(1)}ms queue=${queueMs.toStringAsFixed(1)}ms '
        'realtimeX=${realtimeX.toStringAsFixed(2)} '
        'backlog=${_cumDeficitMs.toStringAsFixed(0)}ms');
  }

  void _stop() {
    final session = _session;
    if (session == null) {
      _toClient.send(<dynamic>[_kFinalized, null]);
      return;
    }
    try {
      final result = session.finalizeAyah();
      _toClient.send(<dynamic>[_kFinalized, result]);
    } catch (e, st) {
      _toClient.send(<dynamic>[_kError, 'Could not finalize: $e\n$st']);
      _toClient.send(<dynamic>[_kFinalized, null]);
    } finally {
      _session = null;
      _streamer = null;
    }
  }

  void _dispose() {
    try {
      _model.dispose();
      _vad?.dispose();
    } catch (_) {
      // Best-effort native teardown; the isolate is going away regardless.
    }
    _session = null;
    _streamer = null;
    _commandPort.close();
  }

  static String _refKey(int sura, int ayah) => '$sura:$ayah';
}

/// Serves the target ayah and its preloaded successor from references shipped
/// in with the start command — the worker never calls the phonetizer itself.
class _CachedReferenceLoader implements AyahReferenceLoader {
  _CachedReferenceLoader(this._cache);

  final Map<String, AyahReference> _cache;

  @override
  Future<AyahReference> load({required int sura, required int ayah}) async {
    final ref = _cache['$sura:$ayah'];
    if (ref == null) {
      // Only the target + immediate successor are preloaded; any further
      // lookahead (chained auto-advance) is unavailable. The session catches
      // this and treats it as "no next ayah".
      throw StateError('No preloaded reference for $sura:$ayah');
    }
    return ref;
  }
}
