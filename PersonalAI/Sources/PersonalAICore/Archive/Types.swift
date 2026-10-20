import Foundation

public enum Role: String, Sendable, Codable, CaseIterable {
    case user, assistant, system, tool
}

/// Where an assistant message was generated. Surfaced in the UI so cloud output is never mistaken for local.
public enum Locality: String, Sendable, Codable {
    case imported, local, cloud
}

public struct NewMessage: Sendable {
    public var role: Role
    public var text: String
    public var createdAt: Double
    public var externalID: String?
    public var model: String?
    public var locality: Locality
    public var meta: String?
    public init(role: Role, text: String, createdAt: Double, externalID: String? = nil, model: String? = nil,
                locality: Locality = .imported, meta: String? = nil) {
        self.role = role; self.text = text; self.createdAt = createdAt; self.externalID = externalID
        self.model = model; self.locality = locality; self.meta = meta
    }
}

public struct MessageRecord: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var conversationID: Int64
    public var seq: Int
    public var role: Role
    public var text: String
    public var createdAt: Double
    public var externalID: String?
    public var model: String?
    public var locality: Locality
    public var meta: String?
    public var date: Date { Date(timeIntervalSince1970: createdAt) }
}

public struct ConversationRecord: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var sourceID: Int64
    public var externalID: String?
    public var title: String
    public var createdAt: Double
    public var updatedAt: Double
    public var origin: String
    public var messageCount: Int
}

public struct AppendResult: Sendable {
    public var inserted: Int
    public var duplicates: Int
    public var firstMessageID: Int64?
    public var lastMessageID: Int64?
}

public struct ImportReport: Sendable {
    public var conversationsSeen = 0
    public var conversationsNew = 0
    public var messagesInserted = 0
    public var messagesDuplicate = 0
    public var skipped = 0
    public var warnings: [String] = []
    public var elapsed: Double = 0
    public init() {}
}

public struct StorageStats: Sendable {
    public var conversations: Int
    public var messages: Int
    public var chunks: Int
    public var chunksPending: Int
    public var vectors: Int
    public var memories: Int
    public var assets: Int
    public var dbBytes: Int64
}

extension MessageRecord {
    init(row: Row) {
        id = row.int(0); conversationID = row.int(1); seq = Int(row.int(2))
        role = Role(rawValue: row.text(3)) ?? .user
        text = row.text(4); createdAt = row.double(5); externalID = row.optText(6)
        model = row.optText(7); locality = Locality(rawValue: row.text(8)) ?? .imported; meta = row.optText(9)
    }
    static let columns = "id, conversation_id, seq, role, text, created_at, external_id, model, locality, meta"
}

extension ConversationRecord {
    init(row: Row) {
        id = row.int(0); sourceID = row.int(1); externalID = row.optText(2)
        title = row.optText(3) ?? "Untitled"; createdAt = row.optDouble(4) ?? 0; updatedAt = row.optDouble(5) ?? 0
        origin = row.text(6); messageCount = Int(row.int(7))
    }
    static let columns = "id, source_id, external_id, title, created_at, updated_at, origin, message_count"
}
