# Personal AI — a local-first assistant for iPhone

A native SwiftUI app that runs chat models on the phone with Apple's MLX, remembers your past conversations (imported or made in the app) with evidence you can inspect, and never sends your data anywhere. This folder is isolated from the rest of the repository.

**Read first:** [`docs/STATUS.md`](docs/STATUS.md) (what is verified where) and [`docs/LIMITATIONS.md`](docs/LIMITATIONS.md).

| Doc | What it covers |
|---|---|
| [STATUS](docs/STATUS.md) | Four-level status matrix: source / Linux / macOS CI / physical iPhone |
| [DISTRIBUTION](docs/DISTRIBUTION.md) | Getting the app on your iPhone with no Mac (free sideload vs TestFlight), costs, signing |
| [CI](docs/CI.md) | What the hosted macOS pipeline runs and costs |
| [ARCHITECTURE](docs/ARCHITECTURE.md) | Modules, data model, retrieval, context, memory |
| [MODELS](docs/MODELS.md) | Catalogue, what was verified, context/KV maths |
| [EVAL](docs/EVAL.md) | End-to-end memory evaluation, vector study, on-device protocol |
| [PERFORMANCE](docs/PERFORMANCE.md) | Measured vs projected vs not measured |
| [PRIVACY](docs/PRIVACY.md) | Guarantees and the mechanism behind each |
| [ROADMAP](docs/ROADMAP.md) | What to do next |

## Layout
```
Package.swift            SwiftPM: PersonalAICore (portable), paibench, paieval, tests
Sources/PersonalAICore   archive · search · memory · retrieval · context · chat · models · eval
Sources/paibench         scale + vector benchmark (Linux/macOS)
Sources/paieval          end-to-end memory evaluation
Tests/                   40+ tests (Linux and macOS)
App/                     XcodeGen project.yml + SwiftUI app (iOS 17+)
tools/embed_server.py    ONNX MiniLM server used only by the Linux evaluation
docs/benchmarks/         raw JSON results
```

## Develop on Linux
```
swift test --skip EndToEndTests/testNeuralPipelineMeetsRetrievalFloors
swift run -c release paibench --sizes 100000,500000 --out /tmp/out.json
PAI_MINILM_DIR=/tmp/minilm swift run paieval --embedder minilm --noise 2000    # see docs/EVAL.md for the model files
```
## Build the app without a Mac
Push to the branch; GitHub Actions builds on macOS and uploads an `.ipa` (see [DISTRIBUTION](docs/DISTRIBUTION.md)). To build locally on a Mac: `brew install xcodegen && cd App && xcodegen generate && open PersonalAIApp.xcodeproj`.

## First run on the phone
Onboarding → pick a model (Qwen3 4B suggested) → it downloads over Wi‑Fi → Library → import your ChatGPT/Claude export → Models → *Measure this iPhone*.
