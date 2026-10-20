import Foundation

public struct ChatMessage: Sendable, Equatable {
    public var role: Role
    public var content: String
    public init(role: Role, content: String) { self.role = role; self.content = content }
}

/// What the loaded model can do on this device. `measured*` fields are filled from on-device benchmarks (never guessed constants).
public struct ModelProfile: Sendable {
    public var id: String
    public var maxContext: Int                // architectural limit
    public var weightsBytes: Int
    public var kvBytesPerToken: Int           // per-model; hybrid/linear-attention models are far smaller than full-attention ones
    public var measuredPrefillTPS: Double?    // tokens/s while processing prompt
    public var measuredDecodeTPS: Double?
    public var supportsPrefixCache: Bool
    public init(id: String, maxContext: Int, weightsBytes: Int, kvBytesPerToken: Int, measuredPrefillTPS: Double? = nil,
                measuredDecodeTPS: Double? = nil, supportsPrefixCache: Bool = true) {
        self.id = id; self.maxContext = maxContext; self.weightsBytes = weightsBytes; self.kvBytesPerToken = kvBytesPerToken
        self.measuredPrefillTPS = measuredPrefillTPS; self.measuredDecodeTPS = measuredDecodeTPS; self.supportsPrefixCache = supportsPrefixCache
    }
}

public enum ThermalLevel: Int, Sendable { case nominal = 0, fair, serious, critical }

public struct DeviceBudget: Sendable {
    /// `os_proc_available_memory()` on iOS: the real per-process headroom, which is far below physical RAM.
    public var availableMemoryBytes: Int
    public var thermal: ThermalLevel
    public var lowPowerMode: Bool
    public init(availableMemoryBytes: Int, thermal: ThermalLevel = .nominal, lowPowerMode: Bool = false) {
        self.availableMemoryBytes = availableMemoryBytes; self.thermal = thermal; self.lowPowerMode = lowPowerMode
    }
}

public struct ContextPlan: Sendable {
    public var windowTokens: Int
    public var replyReserve: Int
    public var standingBudget: Int
    public var summaryBudget: Int
    public var evidenceBudget: Int
    public var historyBudget: Int
    public var memoryCeilingTokens: Int
    public var notes: [String]
}

/// Chooses a context size per turn instead of a fixed constant. The binding constraints, in order:
///  1. memory: weights + KV cache + runtime overhead must fit the process budget (jetsam kills, it does not swap),
///  2. latency: uncached prompt tokens ÷ measured prefill speed must stay within a time-to-first-token budget,
///  3. task: a casual question needs a few thousand tokens, a cross-conversation analysis needs far more,
///  4. thermal/power state: sustained heavy prefill is what heats a phone.
public struct ContextPlanner: Sendable {
    public var runtimeOverheadBytes = 700 * 1024 * 1024        // MLX buffers, tokenizer, app UI, SQLite caches
    public var safetyMargin = 0.85                              // never plan to the last byte of headroom
    public var floorTokens = 2048
    public var ttftBudget: [Complexity: Double] = [.trivial: 1.5, .standard: 4, .deep: 10]
    public var capByComplexity: [Complexity: Int] = [.trivial: 3072, .standard: 8192, .deep: 24_576]
    public init() {}

    public func plan(model: ModelProfile, device: DeviceBudget, complexity: Complexity, conversationTokens: Int, cachedPrefixTokens: Int = 0) -> ContextPlan {
        var notes: [String] = []
        let headroom = Double(device.availableMemoryBytes) * safetyMargin - Double(model.weightsBytes) - Double(runtimeOverheadBytes)
        let memCeil = max(floorTokens, Int(max(0, headroom) / Double(max(1, model.kvBytesPerToken))))
        var cap = min(model.maxContext, memCeil, capByComplexity[complexity] ?? 8192)
        if memCeil < (capByComplexity[complexity] ?? 8192) { notes.append("memory-limited to \(memCeil) tokens") }

        switch device.thermal {
        case .serious: cap = min(cap, max(floorTokens, cap / 2)); notes.append("thermal: halved")
        case .critical: cap = min(cap, floorTokens); notes.append("thermal: minimal context")
        default: break
        }
        if device.lowPowerMode { cap = min(cap, max(floorTokens, cap * 3 / 4)); notes.append("low power mode: reduced") }

        // Latency bound applies to *new* tokens only; with a warm prefix cache the history is free.
        let reserve = complexity == .deep ? 1536 : (complexity == .trivial ? 384 : 768)
        var evidence = Int(Double(cap) * (complexity == .deep ? 0.40 : (complexity == .standard ? 0.22 : 0.05)))
        if let pre = model.measuredPrefillTPS, pre > 0 {
            let budget = ttftBudget[complexity] ?? 4
            let maxNew = Int(pre * budget)
            let uncachedHistory = model.supportsPrefixCache ? max(0, conversationTokens - cachedPrefixTokens) : conversationTokens
            let room = max(256, maxNew - uncachedHistory)
            if evidence > room { evidence = room; notes.append("evidence limited by time-to-first-token budget (\(Int(budget))s at \(Int(pre)) tok/s)") }
        }
        let standing = Int(Double(cap) * 0.08)
        let summary = conversationTokens > cap ? Int(Double(cap) * 0.10) : 0
        let history = max(512, cap - reserve - standing - summary - evidence - 400)
        return ContextPlan(windowTokens: cap, replyReserve: reserve, standingBudget: standing, summaryBudget: summary, evidenceBudget: evidence,
                           historyBudget: history, memoryCeilingTokens: memCeil, notes: notes)
    }
}
