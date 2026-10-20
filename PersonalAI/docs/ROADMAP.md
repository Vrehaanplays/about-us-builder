# Next steps, in the order I would do them

1. **Run the device benchmark** (Models → Measure this iPhone) and commit the JSON as `docs/benchmarks/device-iphone17-*.json`. Everything below depends on real numbers. Decide the default model from tokens/s, time-to-first-token and headroom, not from this document.
2. **First real download test**: pick Qwen3 4B 4-bit; confirm the Hub tree parsing, resume after force-quit, and the SHA-256 check against real LFS digests.
3. **Wire LLM-assisted memory extraction** (`EngineTextGenerator: TextGenerator` over `MLXEngine`) as a charging-only background job; add conversation summaries (`summary` table) for the "earlier in this chat" outline. Evaluate with the same quote-verification rule.
4. **Bigger, fresher retrieval eval**: more conversations, real (consented) chat export, a stronger embedder (Qwen3‑Embedding 0.6B or BGE) measured on the phone; decide on a re-ranker only if it moves hit@1 by a clear margin.
5. **Background**: `BGProcessingTask` for indexing, background URLSession for model downloads.
6. **Photos/Files semantic search** (image/text embeddings on device), linking time-near photos into chat evidence.
7. **App lock + optional passcode-derived encryption** for the archive.
8. **Second runtime** behind `InferenceEngine` (Apple Foundation Models for cheap background extraction, or llama.cpp as a fallback) if benchmarks justify it.
