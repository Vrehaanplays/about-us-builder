# Performance: measured, projected, and not measured

**Every number below was measured on a Linux x86 dev box (4 vCPU Intel Xeon 2.1 GHz, 15 GB RAM, virtual disk) with synthetic or non-chat text. None of it is an iPhone number.** An A19 core is faster per thread than this Xeon, flash I/O and memory pressure differ, and the phone throttles. Use these for *scaling shape* (is something linear? does it blow up?), not for promises. Raw files: `docs/benchmarks/*.json`, reproducible with `paibench`.

## 1. Archive at decade scale (`scale-linux-hashing.json`)
Synthetic Zipfian text with per-conversation topics and bursty timestamps, 10 years, hashing (lexical) embedder at 256-d, phone cache profile. Message counts include the planted needles.

| Messages | Insert (msg/s) | Chunks | Embed time (CPU, hashing) | DB size | Bytes/msg | Needle hit@1 / @3 | Query p50 / p95 | Exact vector scan | Peak RSS |
|---|---|---|---|---|---|---|---|---|---|
| 110 k | 4,358 | 47 k | 20 s | 0.11 GB | 1,041 | 1.00 / 1.00 | 13 / 21 ms | 8 ms | 325 MB |
| 535 k | 4,156 | 230 k | 83 s | 0.55 GB | 1,025 | 0.98 / 1.00 | 71 / 87 ms | 46 ms | 732 MB |
| 1.04 M | 4,058 | 446 k | 99 s | 1.07 GB | 1,026 | 0.95 / 1.00 | 142 / 167 ms | 92 ms | 763 MB |
| **1.50 M** | 3,785 | 643 k | 88 s | **1.54 GB** | 1,025 | 0.91 / 1.00 | **206 / 236 ms** | 135 ms | 771 MB |

- 1.5 M messages ≈ the "10 years × 400/day" target (1.46 M). Storage is ≈1 KB per message including full-text and vector indexes (the synthetic average message is short; real chat text with long assistant replies will be larger, so treat 1.5 GB as a lower bound; a real export's size scales with its text).
- Query latency grows linearly with archive size because vector search is an exact scan (see §2) — 206 ms p50 at 1.5 M messages on this box, with background writes only adding ≈20% (p95 249 ms).
- Needle hit@1 falls from 1.00 to 0.91 as noise grows because the hashing embedder is purely lexical and common-word needles collide; hit@3 stayed 1.00. This is a *synthetic-text* retrieval result and says nothing about meaning-based recall (see `EVAL.md`).
- Earlier run (`scale-linux-hashing-v1-old-ivf-policy.json`) used approximate IVF search above 400 k vectors with an un-calibrated probe count and got 0.33–0.36 vector recall (hashing vectors have no cluster structure), plus **8 minutes** of k-means at 448 k vectors. That policy was wrong; it is replaced (below). The file is kept as the record of why.
- Embedding at ≈2.6–7 k chunks/s here is the *hashing* embedder. A neural embedder is far slower: MiniLM-L6 on this CPU ran ≈130 passages/s (≈30 s for 3.9 k messages' chunks). 643 k chunks at 130/s would take ≈1.4 h on this box; on the phone, with MLX on the GPU, it is **unmeasured** (the on-device benchmark reports passages/s and the app indexes newest-first in the background while charging).

## 2. Vector search: exact vs approximate (`vectors-real-minilm.json`)
Details and the recall table are in `EVAL.md` §2. Decision implemented in `VectorIndex`: exact scan up to `384,000,000 / dim` vectors (1 M at 384-d, 1.5 M at 256-d); approximate IVF only above that **and only if** calibration on that very index proves ≥0.9 recall below a full scan, otherwise stay exact. Test: random vectors with no cluster structure stay exact. 8-bit quantisation costs ≈0.5% recall; exact scan costs ≈0.27 ms per 1,000 vectors at 384-d here.

## 3. Operations at 500 k messages (`ops-linux.json`)
| Operation | Result |
|---|---|
| Base: insert 500 k messages / chunk + embed (hashing) | 124 s / 118 s (233 k chunks); DB 608 MB |
| **Incremental import** of 21,288 messages (13.9 MB ChatGPT-format JSON) into the 500 k archive | 5.9 s (3,585 msg/s), through the real importer |
| **Duplicate re-import** of the same file | 3.0 s, **0 inserted**, 21,288 skipped |
| Index only the new data afterwards | 4.9 s for 9,083 new chunks (nothing old re-done) |
| **Photo/file metadata**: 50,000 asset rows (labels, OCR text, GPS, dates) | 1.9 s (26.7 k/s); full-text asset search ≤ 32 ms |
| **Delete** 200 conversations (5,509 messages, 2,345 vectors) | 0.58 s + 0.15 s to physically purge their vectors |
| **Kill -9 during indexing** (child process SIGKILLed at 80 k of 240 k chunks) | `PRAGMA integrity_check` = ok; vectors + pending = chunks (nothing lost, nothing duplicated); resumed and finished in 79 s (only the remaining work) |
| **Full rebuild** of all derived data from the 560 k-message archive | 131 s with the hashing embedder (neural embedding dominates in practice) |

## 4. Retrieval quality, memory pipeline
See `EVAL.md` (41-question end-to-end evaluation; honest first-run 6/9 on the fresh batch).

## 5. On-device cells (all **not measured**)
| Quantity | Status |
|---|---|
| Tokens/s (prefill, decode) of each catalogue model on iPhone 17 | not measured |
| Time to first token at 256…8192-token prompts | not measured |
| KV-prefix reuse benefit (cold vs warm TTFT) | not measured (benchmark step exists) |
| Peak memory / headroom after loading each model | not measured |
| Sustained speed and thermal throttling over 90 s+ | not measured |
| MLX embedder passages/s | not measured |
| Retrieval quality with the on-device embedder | not measured (benchmark runs the same 41 questions) |
| Archive scale on A19 + flash (50 k / 200 k messages) | not measured |
| Battery per hour of indexing / chatting | not measured (benchmark records battery before/after the sustained run only) |

Third-party benchmarks of other iPhones (e.g. Pro models with 12 GB) are not evidence for a base iPhone 17 and are not used here.
