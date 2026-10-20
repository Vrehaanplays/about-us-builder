import Foundation

/// Fast non-cryptographic 64-bit hashes used for dedupe and feature hashing.
/// (Dedupe always confirms by comparing text on a hash hit; collisions can never merge messages.)
public enum Hash64 {
    @inline(__always)
    public static func fnv1a(_ bytes: UnsafeRawBufferPointer, seed: UInt64 = 0xcbf29ce484222325) -> UInt64 {
        var h = seed
        for b in bytes { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        // final avalanche (splitmix64) so low bits are usable for bucketing
        h ^= h >> 30; h = h &* 0xbf58476d1ce4e5b9
        h ^= h >> 27; h = h &* 0x94d049bb133111eb
        h ^= h >> 31
        return h
    }

    public static func of(_ s: String, seed: UInt64 = 0xcbf29ce484222325) -> UInt64 {
        var s = s
        return s.withUTF8 { fnv1a(UnsafeRawBufferPointer($0), seed: seed) }
    }

    public static func int64(_ s: String) -> Int64 { Int64(bitPattern: of(s)) }
}

public enum TextNorm {
    /// Whitespace-collapsed, trimmed. Used for content hashing so trivial formatting differences dedupe.
    public static func collapse(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var prevSpace = true
        for ch in s.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(ch) {
                if !prevSpace { out.unicodeScalars.append(" "); prevSpace = true }
            } else { out.unicodeScalars.append(ch); prevSpace = false }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Lowercase word tokens (letters/digits), used by hashing embedder, query analysis and Jaccard comparisons.
    public static func words(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in s.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) { cur.unicodeScalars.append(ch) }
            else if !cur.isEmpty { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    public static func jaccard(_ a: String, _ b: String) -> Double {
        let x = Set(words(a)), y = Set(words(b))
        if x.isEmpty && y.isEmpty { return 1 }
        let i = x.intersection(y).count
        let u = x.union(y).count
        return u == 0 ? 0 : Double(i) / Double(u)
    }
}

public enum Clock {
    public static func now() -> Double { Date().timeIntervalSince1970 }
}
