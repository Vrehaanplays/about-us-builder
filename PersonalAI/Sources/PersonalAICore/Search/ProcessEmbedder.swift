#if os(Linux) || os(macOS)
import Foundation

/// Evaluation-only embedder that talks to `tools/embed_server.py` over stdio. Not available on iOS (no subprocesses) and never
/// used by the app: it lets the Linux test/eval harness measure retrieval quality with a real neural model.
public final class ProcessEmbedder: TextEmbedder, @unchecked Sendable {
    public let id: String
    public let dim: Int
    public var maxInputTokens: Int { 256 }
    private let proc = Process()
    private let input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()

    /// Returns nil when python / model files are missing so callers can skip rather than fail.
    public init?(script: String, modelDir: String, id: String = "minilm-l6-v2-onnx", dim: Int = 384, python: String = "python3") {
        guard FileManager.default.fileExists(atPath: modelDir + "/model.onnx"), FileManager.default.fileExists(atPath: script) else { return nil }
        self.id = id; self.dim = dim
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [python, script]
        var env = ProcessInfo.processInfo.environment; env["PAI_MINILM_DIR"] = modelDir
        proc.environment = env
        proc.standardInput = input; proc.standardOutput = output
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
    }
    deinit { try? input.fileHandleForWriting.close(); proc.terminate() }

    public func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        var out: [[Float]] = []
        var i = 0
        while i < texts.count {
            let part = Array(texts[i..<min(i + 64, texts.count)]); i += 64
            out += try roundTrip(part)
        }
        return out
    }

    private func roundTrip(_ texts: [String]) throws -> [[Float]] {
        lock.lock(); defer { lock.unlock() }
        let req = try JSONSerialization.data(withJSONObject: ["texts": texts]) + Data([10])
        try input.fileHandleForWriting.write(contentsOf: req)
        while true {
            if let nl = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<nl]; buffer = Data(buffer[(nl + 1)...])
                guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any], let vs = obj["vectors"] as? [[Double]] else { throw NSError(domain: "ProcessEmbedder", code: 1) }
                return vs.map { $0.map(Float.init) }
            }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { throw NSError(domain: "ProcessEmbedder", code: 2, userInfo: [NSLocalizedDescriptionKey: "embedding server exited"]) }
            buffer.append(chunk)
        }
    }
}
#endif
