import Foundation

public enum Intent: String, Sendable, CaseIterable { case recall, findOriginal, findAsset, compare, timeline, connections, general }
public enum Complexity: Int, Sendable, Comparable {
    case trivial = 0, standard = 1, deep = 2
    public static func < (a: Complexity, b: Complexity) -> Bool { a.rawValue < b.rawValue }
}

public struct QueryPlan: Sendable {
    public var query: String
    public var phrases: [String]
    public var terms: [String]
    public var time: TimeConstraint?
    public var intents: Set<Intent>
    public var entityIDs: [Int64]
    public var wantsPhoto: Bool
    public var wantsFile: Bool
    public var roleBias: Role?
    public var complexity: Complexity
    public var needsRetrieval: Bool
    public var referential: Bool          // explicit pointer to past conversation ("last time", "we talked about")
}

/// Turns the user's message into a retrieval plan without any model call (sub-millisecond).
/// The plan decides *whether* to retrieve, how deep, and with which filters, so simple chats never pay for memory work.
public struct QueryAnalyzer: Sendable {
    public var timeParser: TimeParser
    public init(timeParser: TimeParser = TimeParser()) { self.timeParser = timeParser }

    static let stop: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "is", "it", "that", "for", "on", "with", "as", "was", "are", "be", "this", "i", "you", "my", "me", "we", "do", "did", "at", "by", "so", "but", "what", "when", "where", "who", "how", "why", "which", "about", "from", "have", "has", "had", "can", "could", "would", "should", "will", "your", "our", "us", "them", "they", "he", "she", "his", "her", "there", "then", "than", "not", "no", "any", "some", "if", "just", "also", "very", "really", "into", "out", "up", "down", "over", "am", "were", "been", "being", "its", "these", "those", "ago", "while", "now", "still", "again", "get", "got", "make", "made", "tell", "say", "said", "talk", "talked", "talking", "discuss", "discussed", "mention", "mentioned", "remember", "find", "show", "give", "look", "looking", "search", "message", "messages", "conversation", "conversations", "chat", "chats", "photo", "photos", "picture", "pictures", "image", "images", "file", "files", "document", "documents", "last", "time", "earlier", "before", "previous", "previously", "back", "ever", "original", "exact", "exactly", "words", "one", "thing", "things", "stuff", "something", "anything", "think", "thought", "know", "knew", "week", "weeks", "month", "months", "year", "years", "day", "days", "yesterday", "today", "recently", "lately", "few", "couple", "several"]
    static let trivialExact: Set<String> = ["hi", "hello", "hey", "thanks", "thank you", "ok", "okay", "yes", "no", "yep", "nope", "continue", "go on", "next", "more", "sure", "cool", "great", "nice", "lol", "good morning", "good night", "stop", "retry", "again"]

    public func analyze(_ query: String, now: Date = Date(), entities: EntityStore? = nil, hasHistory: Bool = true) -> QueryPlan {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = q.lowercased()

        // quoted phrases
        var phrases: [String] = []
        var rest = q
        let quoted = try! NSRegularExpression(pattern: #"["“”]([^"“”]{3,120})["“”]"#)
        for m in quoted.matches(in: q, range: NSRange(location: 0, length: (q as NSString).length)).reversed() {
            phrases.append((q as NSString).substring(with: m.range(at: 1)))
            rest = (rest as NSString).replacingCharacters(in: m.range, with: " ")
        }
        phrases.reverse()

        var intents = Set<Intent>()
        func has(_ keys: [String]) -> Bool { keys.contains { lower.contains($0) } }
        if has(["original message", "exact words", "where i said", "where i wrote", "what exactly did i", "find the message", "the message where", "word for word", "verbatim", "when i said"]) { intents.insert(.findOriginal) }
        let wantsPhoto = lower.range(of: #"\b(photo|photos|picture|pictures|pic|pics|screenshot|screenshots|selfie|image|images)\b"#, options: .regularExpression) != nil
        let wantsFile = lower.range(of: #"\b(file|files|document|documents|pdf|doc|docs|spreadsheet|attachment|attachments)\b"#, options: .regularExpression) != nil
        if wantsPhoto || wantsFile { intents.insert(.findAsset) }
        if has(["what changed", "changed my mind", "earlier and later", "used to", "difference between my", "evolved", "over time", "no longer", "anymore", "any more", "earlier view", "my earlier", "compared to"]) { intents.insert(.compare) }
        if has(["timeline", "history of", "over the years", "chronolog", "when did", "how long have", "since when"]) { intents.insert(.timeline) }
        if has(["connected to", "related to", "conversations about", "everything about", "all my chats", "show me the conversations", "other conversations", "anything else about", "associated with"]) { intents.insert(.connections) }
        let referential = has(["remember", "last time", "we talked", "we discussed", "earlier", "before", "previous", "you told me", "i told you", "i mentioned", "what did i", "did i ever", "we decided", "i decided", "as i said", "like i said", "our conversation", "that thing", "continue with", "pick up where", "back to"])
        if referential { intents.insert(.recall) }
        if intents.isEmpty { intents.insert(.general) }

        let time = timeParser.parse(q, now: now)
        let words = TextNorm.words(rest)
        let terms = Array(NSOrderedSet(array: words.filter { !Self.stop.contains($0) && $0.count > 1 })) as! [String]
        let entityIDs = (try? entities?.findMentions(in: q)) ?? []

        var roleBias: Role?
        if lower.contains("where i said") || lower.contains("when i said") || lower.contains("what did i say") || lower.contains("i told you") || lower.contains("i mentioned") { roleBias = .user }

        // how much work does this turn deserve?
        let wordCount = words.count
        var complexity: Complexity = .standard
        if Self.trivialExact.contains(lower.trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))) || (wordCount <= 2 && terms.isEmpty && entityIDs.isEmpty && !referential) { complexity = .trivial }
        if !intents.isDisjoint(with: [.compare, .timeline, .connections, .findOriginal]) || entityIDs.count >= 2 || wordCount > 45 { complexity = .deep }
        let needs = hasHistory && complexity != .trivial && (referential || !terms.isEmpty || !entityIDs.isEmpty || !phrases.isEmpty || intents.contains(.findAsset))

        return QueryPlan(query: q, phrases: phrases, terms: terms, time: time, intents: intents, entityIDs: entityIDs, wantsPhoto: wantsPhoto, wantsFile: wantsFile,
                         roleBias: roleBias, complexity: complexity, needsRetrieval: needs, referential: referential)
    }
}
