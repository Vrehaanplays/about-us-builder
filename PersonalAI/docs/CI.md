# Continuous integration

Workflow: `.github/workflows/personalai.yml`. Triggers: pushes touching `PersonalAI/**`, pull requests, and manual dispatch.

| Job | Runner | What it proves |
|---|---|---|
| Core tests (Linux) | `ubuntu-24.04`, Swift 6.1 | Platform-neutral core builds and passes its tests on Linux |
| Core tests (macOS) | `macos-26` (Xcode 26.x) | The same core compiles and passes on Apple's toolchain and system SQLite |
| iOS app | `macos-26` | XcodeGen project generates; Swift packages (MLX, tokenizers, ZIP) resolve; the app **builds for iOS Simulator**; the unit-test bundle runs on a Simulator; an **unsigned Release build for a real device** is produced and packaged as an `.ipa` artifact |
| TestFlight (manual) | `macos-26` | Signed archive + upload; requires secrets (`docs/DISTRIBUTION.md`); never run so far |

What CI cannot prove: MLX inference on a real GPU (Simulators have no usable Metal/MLX path), real speed, memory pressure, battery, thermals, Photos/Files permission flows on a device. Those need the physical iPhone and the in-app benchmark (`docs/EVAL.md`).

## Cost
- This repository is **public**, so standard GitHub-hosted runners (including macOS) are free.
- If it were private: standard macOS runners are metered; third-party price pages in 2026 list about $0.062/min for the standard macOS runner, with a monthly included allowance on paid plans whose macOS multiplier I could not confirm from GitHub's own page. A full run takes roughly 10–15 minutes. Check GitHub's billing page before making the repo private.
- Concurrency control cancels superseded runs on the same branch to avoid wasted minutes.

## Reproducing locally on Linux
```
cd PersonalAI
swift test --skip EndToEndTests/testNeuralPipelineMeetsRetrievalFloors   # what CI runs
swift build -c release && .build/release/paibench --help                  # benchmark harness
```
