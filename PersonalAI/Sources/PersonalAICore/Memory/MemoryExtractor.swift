import Foundation

/// Anything that can produce text from a prompt: the on-device model in the app, a scripted fake in tests.
public protocol TextGenerator: Sendable {
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
    var modelName: String { get }
}

public struct ExtractionReport: Sendable {
    public var created = 0, reinforced = 0, superseded = 0, disputed = 0, history = 0
    public var rejected: [String] = []
    public var entitiesCreated = 0
    public var ambiguousSkipped = 0
    public var windowsProcessed = 0
}

// MARK: - rules (free: no model needed)

/// Deterministic extraction of explicit first-person statements. Every result quotes the user's own sentence.
public struct RuleExtractor: Sendable {
    public init() {}

    struct Rule: @unchecked Sendable { let pattern: NSRegularExpression; let kind: MemoryKind; let attribute: String?; let cardinality: Cardinality; let standing: Bool; let render: (String) -> String }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }

    static let rules: [Rule] = [
        Rule(pattern: re(#"\bmy name is ([A-Z][\p{L}'\-]+(?: [A-Z][\p{L}'\-]+)?)"#), kind: .fact, attribute: "name", cardinality: .single, standing: false, render: { "The user's name is \($0)" }),
        Rule(pattern: re(#"\bI (?:currently )?live in ([A-Z][\p{L}'\- ]{1,40}?)(?:[.,;!?]| and | but |$)"#), kind: .fact, attribute: "residence", cardinality: .single, standing: false, render: { "The user lives in \($0)" }),
        Rule(pattern: re(#"\bI (?:just )?moved to ([A-Z][\p{L}'\- ]{1,40}?)(?:[.,;!?]| and | but |$)"#), kind: .fact, attribute: "residence", cardinality: .single, standing: false, render: { "The user moved to \($0)" }),
        Rule(pattern: re(#"\bI work (?:at|for) ([A-Z][\p{L}&'\-. ]{1,40}?)(?:[.,;!?]| as | and | but |$)"#), kind: .fact, attribute: "employer", cardinality: .single, standing: false, render: { "The user works at \($0)" }),
        Rule(pattern: re(#"\bI(?:'m| am) allergic to ([\p{L} ,\-]{2,40}?)(?:[.;!?]|$)"#), kind: .constraint, attribute: nil, cardinality: .multi, standing: true, render: { "The user is allergic to \($0)" }),
        Rule(pattern: re(#"\bmy favou?rite ([\p{L} ]{2,25}?) is ([^.;!?\n]{2,50})"#), kind: .preference, attribute: nil, cardinality: .single, standing: false, render: { $0 }),
        Rule(pattern: re(#"\bI (?:really )?(?:prefer|like|love|enjoy) ([^.;!?\n]{3,60})"#), kind: .preference, attribute: nil, cardinality: .multi, standing: false, render: { "The user likes \($0)" }),
        Rule(pattern: re(#"\bI (?:really )?(?:hate|dislike|can't stand|cannot stand) ([^.;!?\n]{3,60})"#), kind: .preference, attribute: nil, cardinality: .multi, standing: false, render: { "The user dislikes \($0)" }),
        Rule(pattern: re(#"\bI (?:decided|have decided|chose|am going) to ([^.;!?\n]{4,80})"#), kind: .decision, attribute: nil, cardinality: .multi, standing: false, render: { "The user decided to \($0)" }),
        Rule(pattern: re(#"\bI(?:'m| am) (?:trying|planning|aiming|hoping) to ([^.;!?\n]{4,80})"#), kind: .goal, attribute: nil, cardinality: .multi, standing: false, render: { "The user is working toward: \($0)" }),
    ]

    nonisolated(unsafe) static let directive = re(#"(?:^|[.!?]\s+)(?:please\s+)?(?:remember (?:that )?|from now on,? |always |never )([^.!?\n]{4,140})"#)

    public func candidates(for m: MessageRecord, conversationID: Int64) -> [CandidateMemory] {
        guard m.role == .user else { return [] }
        var out: [CandidateMemory] = []
        let text = m.text
        let ns = text as NSString
        for rule in Self.rules {
            for match in rule.pattern.matches(in: text, range: NSRange(location: 0, length: min(ns.length, 4000))) {
                let sentence = Self.sentence(containing: match.range, in: ns)
                var value = match.numberOfRanges > 1 ? ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces) : ""
                var statement = rule.render(value)
                if match.numberOfRanges > 2 {   // "my favourite X is Y"
                    let what = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces).lowercased()
                    value = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    statement = "The user's favourite \(what) is \(value)"
                    out.append(CandidateMemory(kind: .preference, epistemic: .stated, attribute: "favourite_" + what.replacingOccurrences(of: " ", with: "_"), text: statement, value: value,
                                               evidence: [CandidateEvidence(messageID: m.id, quote: sentence)], createdBy: "rule"))
                    continue
                }
                if value.isEmpty { continue }
                out.append(CandidateMemory(kind: rule.kind, epistemic: .stated, attribute: rule.attribute, cardinality: rule.cardinality, text: statement, value: value,
                                           standing: rule.standing, evidence: [CandidateEvidence(messageID: m.id, quote: sentence)], createdBy: "rule"))
            }
        }
        for match in Self.directive.matches(in: text, range: NSRange(location: 0, length: min(ns.length, 4000))) {
            let sentence = Self.sentence(containing: match.range, in: ns)
            let body = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let lead = ns.substring(with: match.range).lowercased()
            let isRule = lead.contains("always") || lead.contains("never") || lead.contains("from now on")
            out.append(CandidateMemory(kind: isRule ? .preference : .fact, epistemic: .stated, text: "The user said: \(lead.contains("remember") ? "remember that " : "")\(isRule ? lead.trimmingCharacters(in: CharacterSet(charactersIn: ".!? ")) : body)",
                                       standing: isRule, evidence: [CandidateEvidence(messageID: m.id, quote: sentence)], createdBy: "rule"))
        }
        return out
    }

    static func sentence(containing r: NSRange, in ns: NSString) -> String {
        var start = r.location, end = r.location + r.length
        while start > 0, !".!?\n".contains(ns.character(at: start - 1).asChar) { start -= 1 }
        while end < ns.length, !".!?\n".contains(ns.character(at: end).asChar) { end += 1 }
        if end < ns.length { end += 1 }
        return ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension unichar { var asChar: Character { Character(UnicodeScalar(self) ?? " ") } }

// MARK: - model-assisted extraction (richer; runs only when the user is idle and the runtime is free)

public final class MemoryExtractor: @unchecked Sendable {
    let archive: ArchiveStore
    let memory: MemoryStore
    let entities: EntityStore
    let generator: TextGenerator?
    let rules = RuleExtractor()
    public var windowMessages = 14
    public var maxCharsPerMessage = 900

    public init(archive: ArchiveStore, memory: MemoryStore, entities: EntityStore, generator: TextGenerator?) {
        self.archive = archive; self.memory = memory; self.entities = entities; self.generator = generator
    }

    static let system = """
    You maintain a careful, evidence-based personal memory. Read the conversation excerpt and extract durable information about the USER.
    Rules:
    - Output ONLY one JSON object: {"entities":[{"name":"","kind":"person|project|place|org|topic|event|thing","aliases":[""],"description":""}],
      "memories":[{"kind":"fact|preference|decision|goal|constraint|commitment|open_thread|event|observation|hypothesis","epistemic":"stated|observed|inferred",
      "attribute":"snake_case key for single-valued things like employer or editor, else null","cardinality":"single|multi","subject":"entity name or null for the user",
      "text":"one self-contained sentence","value":"short value or null","standing":false,"evidence":[{"msg":0,"quote":"EXACT words copied from that message"}]}]}
    - "stated" only if the USER said it in their own message. Anything you are guessing is "inferred". Never present a guess as stated.
    - Every memory needs at least one evidence item whose quote is copied verbatim from a message. No quote, no memory.
    - Do not record what the assistant said as facts about the user. Skip small talk, one-off tasks and anything not likely to matter later.
    - If information changes something earlier (a new job, a changed opinion), still output the new value; do not try to edit old memories.
    - At most 6 memories. If nothing qualifies output {"entities":[],"memories":[]}.
    """

    /// Processes unseen messages of one conversation. `watermark` (last processed seq) is kept in the kv table so work resumes after interruption.
    @discardableResult
    public func extract(conversationID: Int64, maxWindows: Int = 4, shouldContinue: () -> Bool = { true }) async throws -> ExtractionReport {
        var report = ExtractionReport()
        let key = "extract.seq.\(conversationID)"
        var seq = Int(archive.db.kvGet(key) ?? "-1") ?? -1
        for _ in 0..<maxWindows {
            guard shouldContinue() else { break }
            let window = try archive.db.read { try $0.query("SELECT \(MessageRecord.columns) FROM message WHERE conversation_id=? AND seq>? ORDER BY seq LIMIT ?",
                                                             [.int(conversationID), .int(seq), .int(windowMessages)], MessageRecord.init(row:)) }
            guard !window.isEmpty else { break }

            // 1. rules: always, free
            for m in window { for c in rules.candidates(for: m, conversationID: conversationID) { tally(try memory.propose(c), &report) } }

            // 2. model: richer structure, only if a generator is available
            if let generator, window.contains(where: { $0.role == .user && $0.text.count > 30 }) {
                let transcript = window.enumerated().map { i, m in
                    "[\(i)] \(m.role.rawValue.uppercased()) (\(Self.date(m.createdAt))): \(String(m.text.prefix(maxCharsPerMessage)))"
                }.joined(separator: "\n\n")
                let raw = try await generator.complete(system: Self.system, user: "Conversation excerpt:\n\n\(transcript)\n\nJSON:", maxTokens: 900)
                try apply(raw: raw, window: window, conversationID: conversationID, modelName: generator.modelName, report: &report)
            }
            for m in window { try linkMentions(in: m) }
            seq = window.last!.seq
            archive.db.kvSet(key, String(seq))
            report.windowsProcessed += 1
        }
        return report
    }

    static func date(_ t: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); return f.string(from: Date(timeIntervalSince1970: t))
    }

    private func tally(_ o: ProposalOutcome, _ r: inout ExtractionReport) {
        switch o {
        case .created: r.created += 1
        case .reinforced: r.reinforced += 1
        case .supersededPrevious: r.superseded += 1; r.created += 1
        case .recordedAsHistory: r.history += 1
        case .disputed: r.disputed += 1
        case .rejected(let why): r.rejected.append(why)
        }
    }

    func apply(raw: String, window: [MessageRecord], conversationID: Int64, modelName: String, report: inout ExtractionReport) throws {
        guard let obj = Self.firstJSONObject(in: raw) else { report.rejected.append("model output was not valid JSON"); return }
        for e in (JSON.array(obj["entities"]) as? [[String: Any]]) ?? [] {
            guard let name = JSON.string(e["name"]), !name.isEmpty else { continue }
            let kind = JSON.string(e["kind"]) ?? "thing"
            let aliases = (JSON.array(e["aliases"]) as? [String]) ?? []
            switch try entities.resolve(name: name, kind: nil, conversationID: conversationID) {
            case .none:
                try entities.create(kind: kind, name: name, description: JSON.string(e["description"]), aliases: aliases); report.entitiesCreated += 1
            case .found(let id): for a in aliases { try? entities.addAlias(id, a) }
            case .ambiguous: break
            }
        }
        for m in (JSON.array(obj["memories"]) as? [[String: Any]]) ?? [] {
            guard let text = JSON.string(m["text"]), let kind = MemoryKind(rawValue: JSON.string(m["kind"]) ?? "fact") else { continue }
            var subject: Int64?
            if let s = JSON.string(m["subject"]), !s.isEmpty, s.lowercased() != "user" {
                switch try entities.resolve(name: s, kind: nil, conversationID: conversationID) {
                case .found(let id): subject = id
                case .none: subject = try entities.create(kind: "person", name: s)
                case .ambiguous: report.ambiguousSkipped += 1; continue   // never attach a claim to a guessed namesake
                }
            }
            var ev: [CandidateEvidence] = []
            for e in (JSON.array(m["evidence"]) as? [[String: Any]]) ?? [] {
                guard let idx = (e["msg"] as? NSNumber)?.intValue, window.indices.contains(idx), let q = JSON.string(e["quote"]) else { continue }
                ev.append(CandidateEvidence(messageID: window[idx].id, quote: q))
            }
            let cand = CandidateMemory(kind: kind, epistemic: Epistemic(rawValue: JSON.string(m["epistemic"]) ?? "inferred") ?? .inferred,
                                       attribute: (JSON.string(m["attribute"])).flatMap { $0.isEmpty ? nil : $0.lowercased() },
                                       cardinality: Cardinality(rawValue: JSON.string(m["cardinality"]) ?? "multi") ?? .multi, subject: subject, text: text,
                                       value: JSON.string(m["value"]), scopeConversation: (kind == .open_thread_alias) ? conversationID : nil,
                                       standing: (m["standing"] as? Bool) ?? false, evidence: ev, createdBy: "llm:\(modelName)")
            tally(try memory.propose(cand), &report)
        }
    }

    private func linkMentions(in m: MessageRecord) throws {
        let ids = try entities.findMentions(in: m.text)
        for id in ids { try entities.recordMention(entity: id, messageID: m.id, conversationID: m.conversationID, at: m.createdAt) }
    }

    /// Tolerates code fences and chatter around the JSON.
    static func firstJSONObject(in s: String) -> [String: Any]? {
        let u = Array(s.utf8)
        guard let start = u.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        var depth = 0, inStr = false, esc = false
        for i in start..<u.count {
            let c = u[i]
            if inStr { if esc { esc = false } else if c == 0x5C { esc = true } else if c == 0x22 { inStr = false }; continue }
            if c == 0x22 { inStr = true } else if c == 0x7B { depth += 1 } else if c == 0x7D {
                depth -= 1
                if depth == 0 { return (try? JSONSerialization.jsonObject(with: Data(u[start...i]))) as? [String: Any] }
            }
        }
        return nil
    }
}

private extension MemoryKind { static var open_thread_alias: MemoryKind { .openThread } }
