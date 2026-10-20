import Foundation

public enum MemoryKind: String, Sendable, Codable, CaseIterable {
    case fact, preference, decision, goal, constraint, commitment, openThread = "open_thread", event, observation, hypothesis
}

/// How we know it. Never silently upgraded: only user statements (or user confirmation) produce `.stated`.
public enum Epistemic: String, Sendable, Codable, Comparable {
    case inferred, observed, stated
    var rank: Int { switch self { case .inferred: return 0; case .observed: return 1; case .stated: return 2 } }
    public static func < (a: Epistemic, b: Epistemic) -> Bool { a.rank < b.rank }
}

public enum MemoryStatus: String, Sendable, Codable { case active, superseded, disputed, retracted }
public enum UserState: String, Sendable, Codable { case none, confirmed, corrected, rejected }
public enum Cardinality: String, Sendable, Codable { case single, multi }

public struct MemoryRecord: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var kind: MemoryKind
    public var epistemic: Epistemic
    public var attribute: String?
    public var cardinality: Cardinality
    public var subject: Int64?
    public var text: String
    public var value: String?
    public var confidence: Double
    public var status: MemoryStatus
    public var validFrom: Double?
    public var validTo: Double?
    public var scopeConversation: Int64?
    public var standing: Bool
    public var userState: UserState
    public var supersedes: Int64?
    public var createdBy: String
    public var createdAt: Double
    public var updatedAt: Double

    static let columns = "id, kind, epistemic, attribute, cardinality, subject, text, value, confidence, status, valid_from, valid_to, scope_conversation, standing, user_state, supersedes, created_by, created_at, updated_at"
    init(row r: Row) {
        id = r.int(0); kind = MemoryKind(rawValue: r.text(1)) ?? .fact; epistemic = Epistemic(rawValue: r.text(2)) ?? .inferred
        attribute = r.optText(3); cardinality = Cardinality(rawValue: r.text(4)) ?? .single; subject = r.optInt(5)
        text = r.text(6); value = r.optText(7); confidence = r.double(8); status = MemoryStatus(rawValue: r.text(9)) ?? .active
        validFrom = r.optDouble(10); validTo = r.optDouble(11); scopeConversation = r.optInt(12); standing = r.int(13) != 0
        userState = UserState(rawValue: r.text(14)) ?? .none; supersedes = r.optInt(15); createdBy = r.text(16)
        createdAt = r.double(17); updatedAt = r.double(18)
    }
}

public struct CandidateEvidence: Sendable {
    public var messageID: Int64
    public var quote: String
    public var contradicts: Bool
    public init(messageID: Int64, quote: String, contradicts: Bool = false) { self.messageID = messageID; self.quote = quote; self.contradicts = contradicts }
}

public struct CandidateMemory: Sendable {
    public var kind: MemoryKind
    public var epistemic: Epistemic
    public var attribute: String?
    public var cardinality: Cardinality
    public var subject: Int64?
    public var text: String
    public var value: String?
    public var validFrom: Double?
    public var scopeConversation: Int64?
    public var standing: Bool
    public var evidence: [CandidateEvidence]
    public var createdBy: String
    public init(kind: MemoryKind, epistemic: Epistemic, attribute: String? = nil, cardinality: Cardinality = .single, subject: Int64? = nil,
                text: String, value: String? = nil, validFrom: Double? = nil, scopeConversation: Int64? = nil, standing: Bool = false,
                evidence: [CandidateEvidence], createdBy: String) {
        self.kind = kind; self.epistemic = epistemic; self.attribute = attribute; self.cardinality = cardinality; self.subject = subject
        self.text = text; self.value = value; self.validFrom = validFrom; self.scopeConversation = scopeConversation; self.standing = standing
        self.evidence = evidence; self.createdBy = createdBy
    }
}

public enum ProposalOutcome: Sendable, Equatable {
    case created(Int64)
    case reinforced(Int64)
    case supersededPrevious(new: Int64, old: Int64)
    case recordedAsHistory(Int64)           // older than what we already know; kept for the timeline
    case disputed(new: Int64, existing: Int64)
    case rejected(String)
}

public struct EvidenceLink: Sendable, Hashable {
    public var memoryID: Int64
    public var messageID: Int64
    public var role: String
    public var speaker: String
    public var quote: String
}

public struct MemoryEventRecord: Sendable {
    public var memoryID: Int64, at: Double
    public var action: String, actor: String, detail: String?
}

public struct MemoryExplanation: Sendable {
    public var memory: MemoryRecord
    public var evidence: [(link: EvidenceLink, message: MessageRecord?)]
    public var events: [MemoryEventRecord]
    public var supersededChain: [MemoryRecord]
}
