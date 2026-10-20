# Known limitations (read before trusting anything)

**Never run on an iPhone 17.** I have no device. CI proves compilation and logic tests only. Everything about real speed, memory, heat and battery is *unmeasured* until you run **Models → Measure this iPhone**.

## Inference
- Which of the catalogue models actually fit and run well on a base iPhone 17 (8 GB, A19) is unknown. The suggestions are a heuristic from parameter counts. `Gemma 4 E4B` is probably too large.
- MLX needs a real GPU: the iOS Simulator cannot be used to judge inference. The Simulator tests in CI avoid MLX at runtime.
- The Hugging Face Hub was unreachable from the build machine, so no model file was downloaded or run during development; the downloader is tested against a simulated server (Range resume, corruption, space checks) but has never talked to the real Hub. Its Hub tree-API parsing is written from the documented response shape and may need a tweak on first use.
- Prefix-cache reuse relies on `ChatSession.fork(history:)`; its behaviour is read from source, and verified on device only if the benchmark's "Prefix reuse" step shows warm TTFT well below cold.
- No Apple Foundation Models runtime, no vision/audio input, no tool use, no agents (by request).

## Retrieval and memory
- Evaluation corpus is tiny, English, hand-written, and the answerer is a quoting stand-in, not an LLM. The only fully fresh result is 6/9 (see `EVAL.md`).
- A 22M-parameter embedder misses some paraphrases buried in long single-topic chats. Stronger embedders are in the catalogue but unmeasured here. A re-ranker is wired (`Reranker` protocol) but none is enabled: there is no evidence yet that one earns its latency and memory.
- Notes are extracted by deterministic rules (explicit first-person statements) only. LLM-assisted extraction and conversation summaries are designed (`TextGenerator`, `summary` table, quote verification) but not connected to the on-device model yet. Expect few notes and no inference about relationships or habits.
- Entity (people, projects) resolution is only as good as notes/rules that create entities; automatic entity extraction needs the LLM tier.
- Photos and files are searchable by OCR text, labels, names, dates and GPS metadata, **not by meaning** (no image embeddings), and not linked into conversations unless an export attached them.
- Zip exports are unpacked with ZIPFoundation; very large zips are fully extracted to a temporary folder first.
- Import formats: ChatGPT and Claude exports, JSONL, plain notes. Other assistants' formats are not supported.

## Scale
- The 1.46M‑message figure is a **projection** unless a row in `docs/benchmarks/scale-*.json` says it was run, and then only on the Linux x86 dev box with synthetic text. Real chat text, an iPhone's flash and its memory limit will differ. The on-device scale test covers 50k and 200k messages only.
- Exact vector search is O(n): about 24 ms for 100k and 137 ms for 500k vectors (384‑d, Linux) — acceptable up to the ≈300k chunks a decade of chat produces, to be confirmed on the phone. IVF above 400k vectors is calibrated per archive but its recall on real chat embeddings is unmeasured.

## Product gaps
- Foreground downloads only (keep the app open); no background URLSession yet.
- No app lock / passcode, no in-app encryption beyond iOS data protection.
- Background indexing runs only while the app is foreground or charging-active; `BGProcessingTask` registration is declared but not implemented.
- Dark mode is the Playbook black scene; there is no separate light-mode illustration set. Lottie/motion beyond springs is not used (nothing needed it).
- Accessibility: Dynamic Type via relative fonts, VoiceOver labels on controls, Reduce Motion respected. Not audited on a device.
