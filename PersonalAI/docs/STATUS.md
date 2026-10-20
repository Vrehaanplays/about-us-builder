# Status report

Legend — the four verification levels you asked for. A cell is ✅ only if that exact thing was observed.
**1** implemented in source · **2** tested on Linux · **3** built and tested on hosted macOS CI · **4** installed and verified on your physical iPhone 17.

**Level 4 is empty everywhere: nothing has been run on an iPhone.** Level 3 evidence: GitHub Actions run [39420244367](https://github.com/Vrehaanplays/about-us-builder/actions/runs/39420244367) (all jobs green) on `macos-26` / Xcode 26.6. Screenshots of the real app running on an iOS Simulator with synthetic data are in `docs/screens/` (Simulator, not an iPhone).

| Capability | 1 | 2 | 3 | 4 | Notes |
|---|---|---|---|---|---|
| Immutable archive, import (ChatGPT/Claude/JSONL), dedupe, erase cascade, export | ✅ | ✅ | ✅ | ⛔ | Real importer on the evaluated path; 21 k-message incremental import 5.9 s, duplicates add 0 |
| Chunking, full-text (FTS5), int8 vector index, exact search | ✅ | ✅ | ✅ | ⛔ | Exact up to ~1 M vectors; approximate only if calibration proves ≥0.9 recall |
| Hybrid retrieval (keywords + vectors + memory + entities + message rescoring) | ✅ | ✅ | ✅ | ⛔ | 41-question end-to-end eval; fresh-batch first run 6/9 (`EVAL.md`) |
| Real neural embedder in evaluation | ✅ | ✅ (MiniLM via ONNX, CPU) | — | ⛔ | CI skips the neural test (no model files); app's MLX embedder never run |
| Memory: rule extraction, supersession, disputes, evidence quotes, corrections | ✅ | ✅ | ✅ | ⛔ | |
| Memory: model-assisted extraction | ✅ | ✅ (scripted generator; fabricated quote rejected) | ✅ compiles | ⛔ | Never run with a real model |
| Context planner, prefix-stable prompt assembly, chat controller (stream, persist, cancel, privacy gate) | ✅ | ✅ | ✅ | ⛔ | 1,500-message chat with the answer at message 17 retrieved |
| Model catalogue, resumable verified downloader (Range, SHA-256, space check, host allow-list) | ✅ | ✅ (simulated server) | ✅ | ⛔ | **Never talked to the real Hugging Face Hub** (unreachable from the dev machine) |
| MLX chat engine (ChatSession fork → KV prefix reuse), MLX embedder | ✅ | n/a (Apple GPU only) | ✅ compiles (Simulator + arm64 Release) | ⛔ | Inference speed/memory unknown |
| SwiftUI app: chat, memory, library, models, privacy, onboarding | ✅ | n/a | ✅ compiles; 8 Simulator unit tests + 2 XCUITest flows that launch the app, walk onboarding and every tab, open a memory's evidence, run a search (WCAG contrast of every colour pair, layout at accessibility text sizes, zip import, privacy defaults) | ⛔ | Never seen on a screen by me; no screenshots |
| Photos (system picker) / Files (folder) indexing with Vision OCR + labels, PDFKit | ✅ | n/a | ✅ compiles | ⛔ | |
| In-app device benchmark (speed, TTFT, prefix reuse, thermals, embedder, retrieval quality, archive scale) | ✅ | core parts ✅ | ✅ compiles | ⛔ | This is the tool that produces level-4 numbers |
| Unsigned Release `.ipa` (arm64, iOS 17+, 11.5 MB) | ✅ | n/a | ✅ built, artifact `personalai-ios` | ⛔ | Not installed anywhere |
| Signed / TestFlight lane | ✅ written | n/a | ⛔ never run | ⛔ | Needs your Apple Developer account + secrets |
| Scale to 1.5 M messages | ✅ | ✅ measured on Linux, synthetic text | n/a | ⛔ | 1.54 GB, query p50 206 ms; phone unmeasured |
| Crash recovery (kill -9 mid-indexing) | ✅ | ✅ | n/a | ⛔ | integrity ok, resumes only remaining work |

## What the green CI run actually proves
- Core package: **49 tests** (printed by CI: `Executed 49 tests, 0 failures`) pass on Linux (Swift 6.1) and on macOS (Xcode 26.6); locally 50 (one more uses MiniLM).
- Unsigned `.ipa` contains the MLX Metal shader library (`default.metallib`, 2.4 MB), so the usual "missing metallib" failure is ruled out; arm64, minimum iOS 17.0.
- App: XcodeGen project generates; Swift packages resolve (mlx-swift 0.32.3, mlx-swift-lm at a pinned commit, swift-transformers, swift-huggingface, ZIPFoundation); the app compiles for iOS Simulator and for a real device (arm64, Release); 8 app unit tests pass on a Simulator.
- It does **not** prove: the app launches, any screen looks right, MLX loads a model, downloads work against the real Hub, Photos/Files flows work, or anything about speed/memory/battery/heat.

## What needs your phone (the shortest path)
1. Get the build onto the iPhone (`DISTRIBUTION.md`).
2. Onboarding → download Qwen3 4B + MiniLM → Models → **Measure this iPhone → Full run** → share the JSON. That single file fills almost every "not measured" cell: tokens/s, TTFT, headroom, prefix-cache benefit, 90-s thermal behaviour, embedder speed, retrieval quality with the on-device embedder, archive scale on A19 flash.
3. Import a real ChatGPT/Claude export (Library) and try a few "what did I say about…" questions.
Send me the JSON and any screenshots/crash logs and the next milestone is concrete.

## Next concrete milestone
Run the device benchmark, pick the default model from its numbers, and fix whatever the first real download/launch reveals (see `ROADMAP.md`).
