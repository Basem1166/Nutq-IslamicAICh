/// Debug switches for the live recitation pipeline.
///
/// [kRecitationTimingLogs] turns on end-to-end timing instrumentation so the
/// real phoneme→word-colour latency (and any worker backlog) can be *measured*
/// on a device instead of guessed at. It emits two correlated log streams:
///
///   * `[timing-worker]` (worker isolate, one line per audio chunk):
///       - `audio`     — the chunk's wall-clock duration (samples ÷ 16 kHz).
///       - `proc`      — inference wall time for the chunk.
///       - `queue`     — how long the chunk sat between the UI sending it and
///                       the worker processing it. **This is the direct backlog
///                       read: if it grows over the ayah, the worker is falling
///                       behind realtime audio.**
///       - `realtimeX` — `proc ÷ audio`; > 1.0 means inference is slower than
///                       realtime and a backlog will accumulate.
///       - `backlog`   — running Σ(proc − audio), floored at 0; the modelled
///                       outstanding backlog, corroborating `queue`.
///
///   * `[timing-ui]` (UI isolate, one line per event):
///       - `STREAM len=…`            — phonemes grew (the "phonemes are on
///                                     screen" moment).
///       - `LIVE idx=… status=…`     — a provisional (non-committed) hint landed.
///       - `WORD idx=… sinceLastPhoneme=…ms` — a word committed and coloured;
///                                     `sinceLastPhoneme` is how long *after* the
///                                     most recent phoneme growth it coloured. A
///                                     small value ⇒ the word committed eagerly
///                                     with the phonemes; a large value (≈ the
///                                     VAD silence window) ⇒ it was gated on the
///                                     pause, not the phonemes.
///
/// Reading it: line up a `WORD` line's `t=` against the `STREAM` line that first
/// carried that word's phonemes — the delta is the felt phoneme→colour lag. A
/// flat `queue`/`backlog` with large `sinceLastPhoneme` points at emission
/// gating; a steadily growing `queue`/`backlog` points at the worker being
/// compute-bound.
///
/// Flip to `false` to silence it. The guards are `const`, so when off the log
/// blocks fold away to nothing (the only residual cost is one cheap
/// `DateTime.now()` per chunk on the send side, which is negligible).
const bool kRecitationTimingLogs = true;

/// Flip to `true` to dump the full error-correction breakdown for every word
/// the session emits, so the corrections shown in the UI can be checked against
/// what the model actually heard. Emits `[correction]` lines on the UI isolate
/// (see [StreamingRecitationController]) at two points:
///
///   * `COMMIT`  — a word's committed result (what the correction drawer shows).
///   * `LIVE`    — a provisional hint, before commit (so you can see whether the
///                 live tint matches the eventual committed correction).
///   * `REPLACE` — a committed word whose result was upserted by a later
///                 recitation (repetition / correction-in-place); shows the
///                 attempt count.
///
/// Each block reports: `status`, `per`, `nRepetitions`, reference-vs-heard
/// phonemes, every [PhonemeError] (kind, expected vs predicted, word-local
/// spans, attached tajweed rules), and every [SifaDiff] (chunk, attribute,
/// expected vs predicted). That is exactly the data the correction drawer
/// renders, so a wrong correction is visible in the log before you trust the
/// UI. `const`-gated, so it folds away entirely when `false`.
const bool kRecitationCorrectionLogs = true;
