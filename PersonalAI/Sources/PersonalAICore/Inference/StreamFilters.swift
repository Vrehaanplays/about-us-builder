import Foundation

/// Removes `<think>…</think>` spans from a token stream, even when the tags are split across chunks.
/// Small on-device models that "reason out loud" would otherwise burn the reply budget and clutter the chat.
public struct ThinkStripper: Sendable {
    private var buffer = ""
    private var inside = false
    public private(set) var strippedCharacters = 0
    public init() {}

    /// Feed a chunk, get the visible text that can safely be shown now.
    public mutating func push(_ chunk: String) -> String {
        buffer += chunk
        var out = ""
        while true {
            if inside {
                if let r = buffer.range(of: "</think>") {
                    strippedCharacters += buffer.distance(from: buffer.startIndex, to: r.upperBound)
                    buffer = String(buffer[r.upperBound...]); inside = false
                    // swallow the blank lines models put after the closing tag
                    while buffer.first == "\n" { buffer.removeFirst() }
                } else {
                    let keep = Self.partialSuffix(of: buffer, tag: "</think>")
                    strippedCharacters += buffer.count - keep; buffer = String(buffer.suffix(keep)); break
                }
            } else {
                if let r = buffer.range(of: "<think>") {
                    out += buffer[buffer.startIndex..<r.lowerBound]
                    buffer = String(buffer[r.upperBound...]); inside = true
                } else {
                    // hold back a possible partial opening tag at the end
                    let keep = Self.partialSuffix(of: buffer, tag: "<think>")
                    out += buffer.dropLast(keep); buffer = String(buffer.suffix(keep)); break
                }
            }
        }
        return out
    }

    public mutating func finish() -> String { defer { buffer = "" }; return inside ? "" : buffer }

    static func partialSuffix(of s: String, tag: String) -> Int {
        let maxLen = min(tag.count - 1, s.count)
        guard maxLen > 0 else { return 0 }
        for n in stride(from: maxLen, through: 1, by: -1) where tag.hasPrefix(String(s.suffix(n))) { return n }
        return 0
    }
}

/// Keeps the KV-cache capacity stable between turns. Changing it forces the runtime to rebuild the cache, which would throw away prefix reuse.
public enum KVTier {
    public static let tiers = [2048, 3072, 4096, 6144, 8192, 12_288, 16_384, 24_576, 32_768, 49_152, 65_536]
    /// Largest tier not above `requested`. Sticks to `current` unless memory demands a smaller one or the plan has doubled.
    public static func choose(requested: Int, current: Int?) -> Int {
        let fit = tiers.last(where: { $0 <= requested }) ?? tiers[0]
        guard let current else { return fit }
        if fit < current { return fit }
        if fit >= current * 2 { return fit }
        return current
    }
}
