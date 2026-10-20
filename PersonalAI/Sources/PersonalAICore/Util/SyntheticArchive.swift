import Foundation

/// Deterministic generator of a realistic-*shaped* personal chat history for tests and scale benchmarks:
/// Zipfian vocabulary, per-conversation topics, lognormal message lengths, bursty timestamps. It is synthetic text,
/// so it exercises storage/index/latency behaviour truthfully but says nothing about semantic retrieval quality.
public struct SyntheticArchive {
    public struct Needle: Sendable { public var messageText: String; public var query: String; public var conversationExternalID: String; public var role: Role }

    public var seed: UInt64 = 1
    public var vocabSize = 40_000
    public var topicCount = 400
    public var topicVocab = 250

    public init(seed: UInt64 = 1) { self.seed = seed }

    struct RNG: RandomNumberGenerator {
        var s: UInt64
        mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    static func makeWord(_ i: Int) -> String {
        // pronounceable pseudo-words; length grows slowly with rank so rare words are longer, like real text
        let c = Array("bcdfghjklmnprstvwz"), v = Array("aeiou")
        var n = i + 7, out = ""
        let syl = 1 + min(3, i / 4000)
        for _ in 0...syl { out.append(c[n % c.count]); n /= c.count; out.append(v[n % v.count]); n = n / v.count + i % 3 }
        return out
    }

    /// Generates `messages` messages (approximately) spread over `years`, returns the needles planted for retrieval evals.
    @discardableResult
    public func generate(into store: ArchiveStore, messages target: Int, avgConversationLength: Int = 24, years: Double = 10, needles needleCount: Int = 0,
                         end: Date = Date(), progress: ((Int) -> Void)? = nil) throws -> [Needle] {
        var rng = RNG(s: seed &* 7919 &+ 13)
        let words = (0..<vocabSize).map(Self.makeWord)
        // Zipf CDF
        var cdf = [Double](repeating: 0, count: vocabSize)
        var acc = 0.0
        for i in 0..<vocabSize { acc += 1.0 / pow(Double(i + 3), 1.05); cdf[i] = acc }
        for i in 0..<vocabSize { cdf[i] /= acc }
        func zipf(_ r: inout RNG) -> Int {
            let u = r.unit(); var lo = 0, hi = vocabSize - 1
            while lo < hi { let m = (lo + hi) / 2; if cdf[m] < u { lo = m + 1 } else { hi = m } }
            return lo
        }
        let topics: [[Int]] = (0..<topicCount).map { t in
            var r = RNG(s: seed &+ UInt64(t) &* 104729)
            return (0..<topicVocab).map { _ in 500 + Int(r.next() % UInt64(vocabSize - 500)) }
        }
        let src = try store.upsertSource(kind: "generic", name: "synthetic", externalID: "synthetic-\(seed)")
        let endT = end.timeIntervalSince1970
        let span = years * 365.25 * 86400
        let conversations = max(1, target / avgConversationLength)
        let needleEvery = needleCount > 0 ? max(1, conversations / needleCount) : Int.max
        var needles: [Needle] = []
        var produced = 0
        var dbSecs = 0.0
        let traceStart = DispatchTime.now()

        let chunkConvs = 64
        var ci = 0
        while ci < conversations {
            try store.batch {
                for _ in 0..<chunkConvs where ci < conversations {
                    defer { ci += 1 }
                    let topic = topics[Int(rng.next() % UInt64(topicCount))]
                    let len = max(2, Int(Double(avgConversationLength) * exp(rng.unit() * 1.6 - 0.8)))
                    var t = endT - rng.unit() * span
                    let ext = "s\(seed)-\(ci)"
                    let (cid, _) = try store.upsertConversation(sourceID: src, externalID: ext, title: "\(words[topic[0]]) \(words[topic[1]])", createdAt: t, updatedAt: t)
                    var msgs: [NewMessage] = []
                    msgs.reserveCapacity(len)
                    for j in 0..<len {
                        let isUser = j % 2 == 0
                        let n = isUser ? 8 + Int(rng.unit() * 30) : 40 + Int(rng.unit() * 140)
                        var parts: [String] = []
                        parts.reserveCapacity(n)
                        for _ in 0..<n { parts.append(rng.unit() < 0.3 ? words[topic[Int(rng.next() % UInt64(topicVocab))]] : words[zipf(&rng)]) }
                        t += isUser ? 20 + rng.unit() * 600 : 5 + rng.unit() * 40
                        msgs.append(NewMessage(role: isUser ? .user : .assistant, text: parts.joined(separator: " "), createdAt: t, externalID: "\(ext)-\(j)"))
                    }
                    if needleCount > 0, ci % needleEvery == 0, needles.count < needleCount {
                        let rare1 = words[vocabSize - 1 - (needles.count * 3) % 2000], rare2 = words[vocabSize - 2 - (needles.count * 5) % 2000]
                        let secret = "zq\(needles.count)x\(Int(rng.next() % 9000) + 1000)"
                        let text = "Remember that my \(rare1) \(secret) deadline is moved because of the \(rare2) review"
                        let pos = Int(rng.next() % UInt64(msgs.count / 2)) * 2
                        msgs[pos].text = text
                        needles.append(Needle(messageText: text, query: "what did I say about the \(rare1) \(secret) deadline", conversationExternalID: ext, role: .user))
                    }
                    let d0 = DispatchTime.now()
                    try store.appendMessages(conversationID: cid, msgs)
                    dbSecs += Double(DispatchTime.now().uptimeNanoseconds - d0.uptimeNanoseconds) / 1e9
                    produced += msgs.count
                }
            }
            progress?(produced)
        }
        if ProcessInfo.processInfo.environment["PAI_TRACE"] != nil {
            let total = Double(DispatchTime.now().uptimeNanoseconds - traceStart.uptimeNanoseconds) / 1e9
            FileHandle.standardError.write(Data(String(format: "[synthetic] %d msgs: total %.1fs, db append %.1fs (%.0f msg/s DB-only)\n", produced, total, dbSecs, Double(produced) / max(dbSecs, 1e-9)).utf8))
        }
        return needles
    }
}
