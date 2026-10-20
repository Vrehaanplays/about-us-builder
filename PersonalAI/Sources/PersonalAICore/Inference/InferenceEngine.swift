import Foundation

public struct GenerationParams: Sendable {
    public var maxTokens = 1024
    public var temperature: Float = 0.6
    public var topP: Float = 0.95
    /// Hard cap on the KV cache (tokens); nil = model default. Set from `ContextPlan` so memory use follows the plan.
    public var maxKVSize: Int?
    /// KV quantisation bits (4/8) chosen by the planner under memory pressure.
    public var kvBits: Int?
    public init() {}
}

public struct GenerationStats: Sendable, Codable {
    public var promptTokens = 0
    public var reusedPrefixTokens = 0
    public var generatedTokens = 0
    public var timeToFirstTokenMs: Double?
    public var tokensPerSecond: Double?
    public var prefillTokensPerSecond: Double?
    public init() {}
}

public enum GenerationEvent: Sendable {
    case token(String)
    case finished(GenerationStats)
}

public struct EngineInfo: Sendable {
    public var name: String
    public var modelID: String
    public var locality: Locality
    public var maxContext: Int
    public init(name: String, modelID: String, locality: Locality, maxContext: Int) { self.name = name; self.modelID = modelID; self.locality = locality; self.maxContext = maxContext }
}

public enum EngineError: Error, LocalizedError, Sendable {
    case notLoaded, cancelled, outOfMemory, remoteNotAllowed
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .notLoaded: return "No model is loaded. Download or select a model first."
        case .cancelled: return "Generation stopped."
        case .outOfMemory: return "The device ran out of memory for this request. Try a shorter context or a smaller model."
        case .remoteNotAllowed: return "Remote processing is switched off. Enable it explicitly in Settings → Privacy if you want it."
        case .failed(let m): return m
        }
    }
}

/// A language-model runtime. MLX is the first implementation; others (Foundation Models, llama.cpp, a remote endpoint) plug in here.
/// Implementations receive the *fully assembled* prompt and must be able to reuse a shared prefix with the previous call.
public protocol InferenceEngine: Sendable {
    var info: EngineInfo? { get async }
    func generate(messages: [ChatMessage], params: GenerationParams) -> AsyncThrowingStream<GenerationEvent, Error>
    func cancel() async
    /// Drop caches and, if asked, weights. Called on memory warnings and when the app is backgrounded.
    func trimMemory(unloadWeights: Bool) async
}

/// Deterministic engine for tests and the UI preview: quotes the most relevant evidence line, token by token.
public final class ScriptedEngine: InferenceEngine, @unchecked Sendable {
    public var reply: @Sendable ([ChatMessage]) -> String
    public var delayPerTokenMs: UInt64 = 0
    public var locality: Locality = .local
    public var failAfterTokens: Int?
    private let lock = NSLock()
    private var cancelled = false
    public private(set) var lastMessages: [ChatMessage] = []
    public private(set) var calls = 0
    public init(reply: @escaping @Sendable ([ChatMessage]) -> String = { m in "You said: \(m.last?.content.suffix(80) ?? "")" }) { self.reply = reply }
    public var info: EngineInfo? { get async { EngineInfo(name: "Scripted", modelID: "scripted", locality: locality, maxContext: 8192) } }
    public func cancel() async { lock.withLock { cancelled = true } }
    public func trimMemory(unloadWeights: Bool) async {}
    public func generate(messages: [ChatMessage], params: GenerationParams) -> AsyncThrowingStream<GenerationEvent, Error> {
        lock.withLock { cancelled = false; lastMessages = messages; calls += 1 }
        let text = reply(messages)
        let delay = delayPerTokenMs
        let failAt = failAfterTokens
        return AsyncThrowingStream { cont in
            Task {
                var stats = GenerationStats(); stats.promptTokens = messages.reduce(0) { $0 + $1.content.count / 4 }
                let words = text.split(separator: " ", omittingEmptySubsequences: false)
                let start = Date()
                for (i, w) in words.enumerated() {
                    let c = self.lock.withLock { self.cancelled }
                    if c { cont.finish(throwing: EngineError.cancelled); return }
                    if i == 0 { stats.timeToFirstTokenMs = Date().timeIntervalSince(start) * 1000 }
                    if let f = failAt, i >= f { cont.finish(throwing: EngineError.failed("simulated failure")); return }
                    cont.yield(.token(i == 0 ? String(w) : " " + w))
                    stats.generatedTokens += 1
                    if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000) }
                }
                cont.yield(.finished(stats)); cont.finish()
            }
        }
    }
}
