import Foundation

/// Tokenizer-agnostic token estimate. The app replaces/calibrates it with the real tokenizer's
/// counts (see `CalibratedTokenCounter`), so context budgeting never depends on a guess for long.
public protocol TokenCounter: Sendable {
    func count(_ text: String) -> Int
}

public struct HeuristicTokenCounter: TokenCounter {
    public var charsPerToken: Double
    public init(charsPerToken: Double = 3.6) { self.charsPerToken = charsPerToken }
    public func count(_ text: String) -> Int {
        if text.isEmpty { return 0 }
        // CJK and emoji are ~1 token per scalar; Latin averages ~3.6 chars/token for modern BPE vocabularies.
        var wide = 0, other = 0
        for u in text.unicodeScalars {
            if u.value >= 0x2E80 { wide += 1 } else { other += 1 }
        }
        return Int((Double(other) / charsPerToken).rounded(.up)) + wide + 1
    }
}

/// Learns chars/token online from (text, trueCount) pairs reported by the real tokenizer.
public final class CalibratedTokenCounter: TokenCounter, @unchecked Sendable {
    private let lock = NSLock()
    private var chars = 0.0, tokens = 0.0
    private let fallback: Double
    private let exact: (@Sendable (String) -> Int)?
    public init(fallback: Double = 3.6, exact: (@Sendable (String) -> Int)? = nil) {
        self.fallback = fallback; self.exact = exact
    }
    public func observe(text: String, tokens t: Int) {
        guard t > 0, text.count > 20 else { return }
        lock.lock(); defer { lock.unlock() }
        // exponential forgetting keeps the estimate tracking the current model's tokenizer
        chars = chars * 0.98 + Double(text.count); tokens = tokens * 0.98 + Double(t)
    }
    public func count(_ text: String) -> Int {
        if let exact { return exact(text) }
        lock.lock(); let c = chars, t = tokens; lock.unlock()
        let ratio = (t > 200 && c > 0) ? c / t : fallback
        return HeuristicTokenCounter(charsPerToken: ratio).count(text)
    }
}
