# Models

## What was verified, and how
- **Runtime:** [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm), pinned to commit `48114eed…` (a 3.x build). Its source was read for: `ChatSession.fork(history:)` (prefix-cache reuse), `GenerateParameters` (`maxKVSize`, `kvBits`), `Downloader`/`TokenizerLoader` protocols, `Memory.cacheLimit/clearCache`, and the model registry. It requires iOS 17+ and builds Metal kernels, so it needs Xcode (CI provides it).
- **Which repo ids exist and run:** each chat id below appears in the pinned runtime's own `LLMRegistry`, i.e. the architecture is implemented by the code we ship. They have **not** been downloaded or run in this environment (the build machine could not reach Hugging Face), and none has run on an iPhone 17.
- **Sizes** in the catalogue are rough placeholders for display. The app asks the Hub for the exact file list (with sizes and SHA-256) before every download and shows the real number.
- **Licences:** only Apache‑2.0 / MIT entries marked "checked" were confirmed from memory of the publishers' model cards; others say "see model card" and the UI says "check the model page". Do not rely on this file for legal compliance.

## Catalogue (App: Models tab; source: `ModelCatalog.swift`)
| Model | Role | Why it is here | Fit on 8 GB (heuristic, unmeasured) |
|---|---|---|---|
| Qwen3 4B (4-bit) — `mlx-community/Qwen3-4B-4bit` | chat, default | strongest general model that should leave room for a long context | suggested |
| Qwen3 1.7B (4-bit) | chat | speed; background extraction | comfortable |
| Qwen3 0.6B (4-bit) | chat | smoke test / small phones | comfortable |
| Gemma 4 E2B / E4B (4-bit) | chat | Google family requested; E4B is likely too large | E2B maybe; E4B probably not |
| Gemma 3 1B QAT (4-bit) | chat | tiny, quantisation-aware | comfortable |
| Llama 3.2 3B (4-bit) | chat | long architectural context | suggested |
| SmolLM3 3B (4-bit) | chat | fully open | suggested |
| all‑MiniLM‑L6‑v2 (384‑d) | embedder, default | the model the retrieval evaluation used | tiny |
| BGE small en v1.5 / multilingual‑E5 small / Qwen3‑Embedding 0.6B | embedder | quality / language options | small |

Qwen3 "thinking" is disabled per request (`enable_thinking=false`) and any stray `<think>` span is stripped from the stream.

## Switching and local‑vs‑cloud labelling
Download / pause / resume / remove / select all work from the card. Every card and every answer carries a **On this iPhone** label; imported messages say **Imported**; there is a **Cloud** label type but no cloud engine, so it is never shown. Changing the embedder deletes the vectors (they live in a different space) and re-queues indexing.

## Context windows
Architectural limits come from the catalogue; the usable window is decided per turn by the planner (memory, time-to-first-token, thermals, question complexity) and can be capped in Settings. KV‑cache cost per token is read from the model's `config.json` after download (formula: 2 × attention layers × KV heads × head dim × bytes per element; hybrid models count only full‑attention layers). Example from the unit test: a 36‑layer, 8‑KV‑head, 128‑dim model costs 147,456 B/token at fp16 → 8k tokens ≈ 1.2 GB, 32k ≈ 4.7 GB, which is why 4B models cannot use their full 32k on this phone and the app bounds the cache (`maxKVSize` tiers, optional 4/8‑bit KV).

## Not yet evaluated
Vision / audio input, speculative decoding, Apple Foundation Models as a second runtime, re‑ranking models. See `ROADMAP.md`.
