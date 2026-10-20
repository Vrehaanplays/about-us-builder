# Evaluation: what is measured, how, and how far to trust it

Two harnesses, both reproducible and both honest about what they are.

| Harness | Where it runs | Embedder | Purpose |
|---|---|---|---|
| `paieval` (Linux/macOS) | dev box / CI | all-MiniLM-L6-v2 (ONNX Runtime, CPU) or the lexical hashing fallback | Retrieval *quality* through the whole pipeline |
| `paibench` (Linux/macOS) | dev box | hashing / real vectors | Throughput, latency, disk and memory at archive scale; vector-search study |
| In-app **Models → Measure this iPhone** | the iPhone | the installed MLX models | The only source of device speed, memory, thermals, prefix-reuse and on-device archive timings |

Nothing produced on Linux is a statement about an iPhone. Every JSON file carries a `host` block saying what machine it came from.

## 1. End-to-end memory pipeline (`paieval`)

Pipeline under test: **real importer** (a ChatGPT-format `conversations.json` is generated from the corpus and imported) → normalise + dedupe → chunk → embed → rule-based memory extraction with supersession → natural-language query analysis → hybrid retrieval (keywords + vectors + memory + entity + message-level rescoring) → ranking → prompt assembly with citation tags → grounded answer → verification.

Corpus (`Sources/PersonalAICore/Eval/EvalCorpus.swift`): 17 hand-written conversations (a 700-message and a 900-message chat with one-line facts buried at message 143 and 61, trips across two chats, a job change, a changed food preference, two people called Alex, an allergy, identifiers, a 2023 chat) plus ≈2,000 messages of synthetic noise. **41 questions**: exact, paraphrase, old conversation, identifier, cross-chat, date-range, recency, correction, conflict, name, same-name ambiguity, and abstention (things never said).

How "answer is supported by evidence" is checked: the model is replaced by an **extractive answerer** that can only quote retrieved text. A case passes only if (a) the gold messages were retrieved (and inside any hard date window), (b) the answer contains the expected facts and none of the forbidden ones (e.g. the old employer), (c) every quoted sentence exists verbatim in the cited archive message or memory **and** in the prompt the model would see, and (d) unanswerable questions are refused. This tests retrieval, ranking, supersession, citation integrity and abstention. It does **not** test an LLM's answer quality; that needs the device.

### Results (3,859 messages, MiniLM-L6-v2 ONNX, Linux x86)

| Question set | Cases | Passed | Notes |
|---|---|---|---|
| Tuned set (used while building retrieval) | 18 | 18 | optimistic by construction |
| `h-` batch, written next | 14 | **12 on first run**, 14 after fixes | the two failures exposed real flaws (see below); after fixing them this batch is no longer independent |
| `g-` batch, written after the fixes, **first-run result, not tuned on** | 9 | **6** | the number to believe |

Failures on the untouched batch: *"when am I flying out in the spring"* (weak match, answerer abstained), *"what the kitchen floor is going to set me back"* (price phrased with no shared words, buried in a 700-message single-topic chat: not retrieved), *"how long did the run take me at the start of the year"* (found at rank 3, low confidence → abstained). MiniLM-L6 (22M parameters) is a small embedder; these are the sort of misses a stronger on-device embedder may fix, but that is a hypothesis until measured on the phone.

Aggregate on all 41 (MiniLM): hit@1 0.83, hit@3 0.94, MRR 0.89, all-gold-evidence 0.97, grounded answer 0.91, abstention 1.00, citations valid 100%.
The lexical fallback (hashing embedder) retrieves 0.69 at hit@3 and cannot do paraphrase: that is why the app labels search as "keyword only" until an embedding model is installed.

Flaws the evaluation found and which are fixed in the code: (1) a chunk's embedding is the average of its neighbours, so a one-line answer inside a long single-topic chat was drowned out → added message-level rescoring of the best chunks; (2) a keyword hit on one common word out of a long question outranked a much better semantic match → lexical channel weight now scales with how many query words are distinctive, and strong semantic margins count; (3) "in October" (a *future* appointment) became a hard filter on when the message was written and returned nothing → future ranges only boost, and a hard window that finds nothing is relaxed once and flagged; (4) after a job change both employers were shown as equals → evidence that supports only a superseded note is labelled **OUTDATED** and shows the current statement.

Limits: the corpus is small, hand-written and English; many questions share a template voice; the noise is random vocabulary, not conversation; one embedder; the stand-in answerer is generous in that it never hallucinates. Do not read 91% as "91% correct on your life".

Reproduce (needs `onnxruntime`, `tokenizers`, `numpy` from PyPI and the ONNX files; the GitHub mirror below was reachable when this was built):
```
mkdir -p /tmp/minilm && cd /tmp/minilm
curl -L -o model.onnx https://media.githubusercontent.com/media/spring-projects/spring-ai/main/models/spring-ai-transformers/src/main/resources/onnx/all-MiniLM-L6-v2/model.onnx
curl -L -o tokenizer.json https://raw.githubusercontent.com/spring-projects/spring-ai/main/models/spring-ai-transformers/src/main/resources/onnx/all-MiniLM-L6-v2/tokenizer.json
cd PersonalAI && swift build --product paieval
PAI_MINILM_DIR=/tmp/minilm .build/debug/paieval --embedder minilm --noise 2000 --out docs/benchmarks/eval-minilm-2000noise.json
```
`swift test` runs the same pipeline with the lexical embedder always, and with MiniLM when those files exist.

## 2. Vector search study on real embeddings (`paibench --vectors-file`)

31,609 real English passages (Python docstrings and docs on the build machine, embedded with MiniLM, 384-d) — *technical English, not chat*. 300 held-out passages are the queries; ground truth is float32 brute force.

| Vectors | int8 exact recall@10 vs float | int8 exact scan | IVF recall@10 at nprobe 16 / 32 / 64 (≈ lists 4–6% / 12% / 24%) |
|---|---|---|---|
| 5,000 | 0.993 | 1.2 ms | 0.94 / 0.97 / 0.99 |
| 20,000 | 0.996 | 4.9 ms | 0.92 / 0.96 / 0.99 |
| 31,309 | 0.993 | 9.3 ms | 0.92 / 0.97 / 0.98 |

Conclusions: 8-bit quantisation costs ≈0.5% recall. IVF only reaches 0.92 recall by probing ≈6% of lists, giving a 4–5× speed-up at 31k vectors (1.9 ms vs 9.3 ms) and **less** at small sizes. The earlier poor IVF recall (0.14–0.21) was caused by the unclustered hashing embedder, not by the index. **Decision:** exact search is the default up to 400k vectors; IVF only above that, calibrated against exact on the user's own data (`VectorIndex.calibrate`). Latency-only scan cost with synthetic vectors (real vectors plus noise): 100k vectors 23.8 ms, 500k vectors 137 ms (384-d, this x86 CPU; iPhone unmeasured). At ≈5 messages per chunk, 1.46M messages ≈ 300k chunks → exact scan ≈ 80 ms here. Files: `docs/benchmarks/vectors-real-minilm.json`.

## 3. On-device protocol (needs the physical iPhone 17)

Models → *Measure this iPhone* (Quick ≈2 min, Full ≈8 min; plug in, start cool). Records, to a JSON file you can share: device/OS/memory headroom/thermal/battery; model load time and weights size; time-to-first-token and prefill/decode tokens-per-second at 256…8192 prompt tokens with headroom after each; **prefix-reuse** (cold vs warm TTFT and reused-token count — verifies the KV-cache reuse claim); a 90 s sustained run (tokens/s first vs last, thermal state, battery); embedder passages/s; and the **archive scale test on the phone** (insert rate, index time, DB size, retrieval p50/p95, needle hit@3) at 50k and 200k messages. Until a file from your phone exists, `docs/PERFORMANCE.md` lists those cells as *not measured*.
