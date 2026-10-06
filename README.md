# Nutq (نُطق)

Nutq is an Islamic AI app with two main features:

- **Live Quran recitation feedback.** The user recites and an on-device speech model (Mualem, a
  Wav2Vec2-BERT multilevel-CTC model exported to ONNX) listens. It aligns the recitation to the
  ayah and flags pronunciation and tajweed mistakes as the user goes.
- **Semantic search over the Quran and Hadith.** Search works in Arabic, English or transliterated
  terms, and is served by a FastAPI backend.

## Repository layout

| Folder | What's inside |
|---|---|
| [`Flutter App/`](Flutter%20App/) | The mobile app (Android / iOS / web). |
| [`SearchEngine/`](SearchEngine/) | The Quran and Hadith search backend that the app's search screen calls. |
| [`Compression/`](Compression/) | Scripts that compress the recitation model and export it for on-device use. |

### `Flutter App/`

The Flutter client (package name `nutq`).

- `lib/core/recitation/`: the on-device recitation pipeline. It covers audio recording, Silero VAD,
  the mel feature extractor, ONNX model inference, CTC decoding, scoring and the streaming
  controller.
- `lib/core/` (other files): reference audio playback, Quran metadata, config and the phonetizer
  service.
- `lib/features/`: the app screens (home, Quran reader, live recitation, search, saved items,
  profile, auth, activity).
- `lib/docs/API_REFERENCE.md`: the API contract for the search backend.
- `packages/quran_recitation_core/`: a pure-Dart package for the streaming recitation logic
  (phoneme chunking, word and phrase alignment, phrase classification). It has no Flutter
  dependency, so it can be tested with `dart test`.
- `android/app/src/main/python/`: the Quran phonetizer (tajweed rules, sifat analysis) in Python.
  It runs on Android through Chaquopy and produces the reference phonemes that recitations are
  scored against.
- `assets/`: the ONNX models (Mualem recitation model, Silero VAD), the model vocabulary, the Quran
  text and the app icon.

Run it with `flutter pub get` and then `flutter run` from inside `Flutter App/`.

### `SearchEngine/`

A FastAPI service for bilingual (Arabic / English) semantic search. The corpus is 6,236 ayahs with
tafsir and translation, plus about 22k hadiths from Bukhari, Muslim, Abu Dawood and Tirmidhi. A
query goes through these steps:

1. Query understanding: transliterations, spelling variants and direct references such as `2:255`.
2. Retrieval: dense vectors (multilingual-e5 + FAISS) and BM25.
3. Fusion: the two result lists are merged with RRF.
4. Reranking: a cross-encoder reorders the merged results.

The folder also has the scripts that build the corpus, embeddings and indexes. See
[`SearchEngine/README.md`](SearchEngine/README.md) for setup, data preparation and running the
server (`uvicorn main:app`).

### `Compression/`

Tooling to make the Mualem recitation model small enough to run on a phone.

- `mualem_pipeline.py`: a pruning → fine-tuning → quantization-aware training (QAT) pipeline for
  Wav2Vec2-BERT.
- `onnx-export-notebook.ipynb`: exports the trained checkpoint (QAT or FP32) to ONNX.
- `convert_onnx_for_android.py`: rewrites the `ConvInteger` nodes made by dynamic quantization
  into float `Conv` nodes. ONNX Runtime has no kernel for `ConvInteger`, so without this step the
  model can't load on mobile.
