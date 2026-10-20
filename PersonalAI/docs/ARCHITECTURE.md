# Architecture

```
┌────────────────────────────── iOS app (App/, SwiftUI, iOS 17+) ──────────────────────────────┐
│ Chats · Memory · Library · Models · Privacy      Playbook "Loud" design system (Design/)      │
│ AppModel (boot, model lifecycle, background work gate)   Benchmark runner (on-device)         │
│ ── Apple/MLX-only code ───────────────────────────────────────────────────────────────────── │
│ MLXEngine (ChatSession.fork → KV prefix reuse)   MLXTextEmbedder   URLSessionTransport        │
│ MediaIndexer (Vision OCR/labels, PDFKit, ImageIO)   DeviceInfo (os_proc_available_memory…)    │
└───────────────────────────────────────────┬──────────────────────────────────────────────────┘
                                            │ protocols: InferenceEngine · TextEmbedder · HTTPTransport
┌───────────────────────────────────────────▼──────────────────────────────────────────────────┐
│ PersonalAICore (Swift package, no Apple frameworks, builds & tests on Linux and macOS)       │
│ Archive (immutable) → Chunker → IndexingPipeline → VectorIndex (int8, exact/IVF)             │
│ Memory (propose/reconcile/supersede/dispute, evidence quotes) · Entities                     │
│ Retrieval: QueryAnalyzer → Lexical + Vector + Memory + Entity + message-level rescoring → RRF│
│ Context: ContextPlanner → PromptAssembler (prefix-stable) → ChatController (stream, persist) │
│ Models: ModelCatalog · ModelStore (resumable, SHA-256 verified) · KVEstimator · NetworkLedger│
│ Eval: EvalCorpus · EvalSuite (used by `paieval`, tests, and the app's benchmark)             │
└───────────────────────────────────────────┬──────────────────────────────────────────────────┘
                                            ▼
                          SQLite (WAL, FTS5) — one file, one writer, pooled readers
```

**Why the split:** Linux can compile and test everything except MLX, SwiftUI and PhotoKit/Vision. Anything with a correctness requirement lives in the portable core so it is tested on every push (Linux and macOS); the app target is thin glue plus UI and is verified by the macOS build.

## Data model (Schema.swift)
- `message` rows are **write-once** (a trigger rejects edits). Everything else is derived and rebuildable: `chunk`, `message_fts`, `vec_block`, `memory`, `entity`, `summary`, `asset` text.
- Dedup on import by external id, else role+timestamp+content hash, so re-importing the same export adds nothing.
- Erase cascades: deleting a conversation removes its messages, FTS rows, chunks, queues vector purges, deletes evidence links, removes notes that only that conversation supported, and weakens notes with other support.

## Retrieval (Retrieval/)
1. **QueryAnalyzer**: intent (find original / compare / timeline / asset), time constraint (hard for past ranges, soft for future/fuzzy), entities, whether retrieval is needed at all ("thanks" skips it).
2. **Channels in parallel**: FTS5 BM25 over *distinctive* terms (document frequency from `fts5vocab`), vector search over chunks, memory search (keywords + vectors), entity mentions.
3. **Message-level rescoring**: the best 12 chunks' user messages are re-embedded and scored individually, because a chunk vector averages its neighbours.
4. **Fusion**: weighted reciprocal-rank fusion; lexical weight scales with query distinctiveness; strong semantic margins boost; recency is a mild multiplier unless the question is a timeline.
5. **Gating**: a candidate must have keyword coverage, a vector score, a memory link or an entity link; otherwise nothing is returned ("I don't have that").
6. **Expansion & diversity**: neighbours of single-message hits, max two spans per conversation (more for deep questions), associative hop for "compare / what else" questions.
7. **Outdated marking**: evidence that only supports a superseded note is labelled with the current statement.
Optional `Reranker` hook exists but no reranker is enabled: none has been shown to pay for its latency and memory (see `LIMITATIONS.md`).

## Context (Context/)
`ContextPlanner` chooses a window per turn from: `os_proc_available_memory`, weights size, KV bytes/token (computed from the model's own `config.json`), time-to-first-token budget given measured prefill speed, question complexity, thermal state and Low Power Mode. `PromptAssembler` lays the prompt out for KV reuse: **system + standing notes + outline of older chat + history (front snapped to a 16-message grid) | evidence + notes attached to the last user message**. `MLXEngine` forks the previous `ChatSession` with the new transcript; mlx-swift-lm keeps the cache for the common prefix and prefills only the rest. Conversations of any length work because the verbatim window is bounded and everything older is retrievable (tested with a 1,500-message chat where the answer sits at message 17).

## Memory (Memory/)
Notes are *derived, source-linked, reversible*. Each has: kind, epistemic status (stated / observed / inferred), confidence with time decay for weak inferences, validity interval, and ≥1 evidence link carrying a **verbatim quote verified against the original message on write**. Single-valued attributes (employer, residence) supersede older values and keep history; contradictory multi-source claims become `disputed` instead of silently winning; your corrections outrank everything and block re-learning. Free tier: deterministic rules over explicit first-person statements. Optional tier: the on-device LLM proposes structured notes through `EngineTextGenerator` (an isolated session, so the chat's KV cache is untouched; cancelled the moment you start typing), still subject to the quote check. Rule and model passes keep separate watermarks, so installing a model later re-reads history the rules already covered.

## Background work
`IndexScheduler` runs small resumable batches (chunk → embed → cluster → extract) gated by `WorkGate`: never while generating or hot, bookkeeping only in Low Power Mode or on battery (default), full speed when foreground/charging. All progress is in SQLite, so a kill loses at most one batch.
