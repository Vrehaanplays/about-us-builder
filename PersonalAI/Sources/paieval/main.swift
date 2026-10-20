import Foundation
import PersonalAICore

// paieval: end-to-end memory-pipeline evaluation (import → index → retrieve → assemble → grounded answer).
//   paieval [--embedder hashing|minilm] [--noise N] [--out report.json] [--script tools/embed_server.py] [--model-dir DIR]
var embedderName = "hashing", noise = 3000, out: String?, chunk = 256, only: String?
var script = "tools/embed_server.py", modelDir = ProcessInfo.processInfo.environment["PAI_MINILM_DIR"] ?? "/tmp/claude-0/minilm"
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--embedder": embedderName = it.next() ?? embedderName
    case "--noise": noise = Int(it.next() ?? "") ?? noise
    case "--chunk": chunk = Int(it.next() ?? "") ?? chunk
    case "--only": only = it.next()
    case "--out": out = it.next()
    case "--script": script = it.next() ?? script
    case "--model-dir": modelDir = it.next() ?? modelDir
    default: print("unknown arg \(a)")
    }
}
let embedder: any TextEmbedder
var real = false
if embedderName == "minilm" {
    guard let e = ProcessEmbedder(script: script, modelDir: modelDir) else { print("MiniLM files or script not found"); exit(2) }
    embedder = e; real = true
} else { embedder = HashingEmbedder(dim: 256) }
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paieval-\(getpid())")
defer { try? FileManager.default.removeItem(at: dir) }
let report = try await EvalSuite.run(embedder: embedder, realEmbedder: real, noiseMessages: noise, dir: dir, chunkTokens: chunk, only: only, log: { print($0) })
print(String(format: "\nembedder=%@ messages=%d  hit@1=%.2f hit@3=%.2f mrr=%.2f allGold=%.2f answer=%.2f abstain=%.2f  import=%.1fs index=%.1fs",
             report.embedder, report.totalMessages, report.hitAt1, report.hitAt3, report.mrr, report.allGoldRate, report.answerRate, report.abstainRate, report.importSeconds, report.indexSeconds))
print(String(format: "tuned-set pass=%.2f  held-out(h-, fixed after first run) pass=%.2f  held-out(g-, first run) pass=%.2f", report.tunedPassRate, report.heldOutPassRate, report.heldOut2PassRate))
print("by category:", report.byCategory.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.2f", $0.value))" }.joined(separator: " "))
if let out {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(report).write(to: URL(fileURLWithPath: out))
}
