import Foundation

/// Yields the top-level elements of a huge JSON array one at a time without parsing the whole file.
/// A 1 GB `conversations.json` export therefore costs memory proportional to the largest single
/// conversation (the file itself is memory-mapped, not read into RAM).
public enum JSONArrayStreamer {
    @inline(__always) static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 }
    public enum StreamError: Error { case notAnArray, unterminated }

    /// `body` receives each element's raw bytes; return false to stop.
    public static func forEachElement(in data: Data, _ body: (Data) throws -> Bool) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            var i = 0
            // skip BOM + whitespace to '['
            if n >= 3, p[0] == 0xEF, p[1] == 0xBB, p[2] == 0xBF { i = 3 }
            while i < n, isSpace(p[i]) { i += 1 }
            guard i < n, p[i] == UInt8(ascii: "[") else { throw StreamError.notAnArray }
            i += 1
            while i < n {
                while i < n, isSpace(p[i]) || p[i] == UInt8(ascii: ",") { i += 1 }
                if i >= n { throw StreamError.unterminated }
                if p[i] == UInt8(ascii: "]") { return }
                let start = i
                var depth = 0
                var inString = false
                var escaped = false
                scan: while i < n {
                    let c = p[i]
                    if inString {
                        if escaped { escaped = false }
                        else if c == UInt8(ascii: "\\") { escaped = true }
                        else if c == UInt8(ascii: "\"") { inString = false; if depth == 0 { i += 1; break scan } }
                    } else {
                        switch c {
                        case UInt8(ascii: "\""): inString = true
                        case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                        case UInt8(ascii: "}"), UInt8(ascii: "]"):
                            depth -= 1
                            if depth == 0 { i += 1; break scan }
                        case UInt8(ascii: ","): if depth == 0 { break scan }
                        default: if depth == 0, isSpace(c) { break scan }
                        }
                    }
                    i += 1
                }
                if depth != 0 || inString { throw StreamError.unterminated }
                let slice = Data(bytes: p.baseAddress!.advanced(by: start), count: i - start)
                if try !body(slice) { return }
            }
            throw StreamError.unterminated
        }
    }
}

public enum ISODate {
    /// Tolerant ISO-8601 parsing (any number of fractional digits, 'Z' or offset).
    public static func parse(_ s: String?) -> Double? {
        guard var s, !s.isEmpty else { return nil }
        if let dot = s.firstIndex(of: ".") {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            let frac = String(s[s.index(after: dot)..<end])
            let ms = String((frac + "000").prefix(3))
            s = String(s[..<dot]) + "." + ms + String(s[end...])
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = s.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f.date(from: s)?.timeIntervalSince1970
    }
}
