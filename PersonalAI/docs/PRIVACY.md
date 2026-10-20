# Privacy: what is guaranteed, and by what mechanism

| Claim | How it is enforced | Where to verify |
|---|---|---|
| Chat inference, embeddings, search, memory extraction and photo/file reading run on the device | The only inference engine in the app is `MLXEngine` (`locality = .local`). There is no HTTP client for inference anywhere in the code | `App/Sources/Runtime/`; grep for `URLSession` finds only `URLSessionTransport` |
| No silent cloud fallback | `ChatController` refuses any engine whose locality is `.cloud` unless `remoteAllowed()` is true; the app sets it to `{ false }` and no cloud engine exists. Tested: nothing is stored or sent when a cloud engine is attempted | `ChatControllerTests.testCloudEngineIsRefused…` |
| The network is used only to download model files | `NetworkPolicy` allow-list (`huggingface.co` and its CDN hosts) checked before every request **and on every redirect**; requests carry no conversation data; every request is recorded in `NetworkLedger` and shown in *Privacy* | `Models/ModelStore.swift`, `URLSessionTransport.swift`, Privacy tab |
| Downloaded models are intact | Size and SHA-256 (from the Hub's LFS digest) verified before a file is moved into place; failures are deleted | `ModelStoreTests` |
| Minimal permissions | No account, no analytics SDK, no location, no contacts. Photos use the system picker (no library permission needed) and the Files picker (you grant one folder at a time). `NSPhotoLibraryUsageDescription` exists only in case a future full-library mode is added | `Info.plist` in `project.yml` |
| You can inspect, correct, export, delete | Memory tab (evidence, history, confirm / correct / reject / delete), Library → Export everything (JSONL + notes with proofs), Delete conversation, Rebuild index, Erase all data | `ServicesTests` |
| Original words are never altered | `message` rows are write-once (DB trigger); derived data is rebuildable | `ArchiveTests` |
| Private text is not logged | Core never calls `print` with message content; the only log path is the opt-in `PAI_TRACE` env var, which is not set in the app | grep `PAI_TRACE` |
| Weak guesses can't override what you said | `stated` > `observed` > `inferred`; inferred notes decay; your correction beats everything | `MemoryTests`, `EvalSuite` correction/conflict cases |

## What is *not* protected
- The archive lives in the app's sandbox, included in iOS device backups like other app data (the models folder is excluded). If you back up unencrypted to a computer, the archive goes with it. Use an encrypted backup or ask for an in-app passcode (not implemented).
- The database is protected by iOS data protection (default class) but is not additionally encrypted by the app.
- Model files come from Hugging Face. Their licences and contents are the publishers'; the app verifies integrity against the Hub's own hashes, which is not an independent signature.
- Anyone who unlocks your phone and opens the app can read your history. There is no app lock yet.
