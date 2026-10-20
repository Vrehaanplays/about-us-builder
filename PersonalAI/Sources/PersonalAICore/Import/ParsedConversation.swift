import Foundation

/// Format-independent intermediate form produced by every importer.
public struct ParsedAttachment: Sendable {
    public var messageExternalID: String
    public var name: String
    public var mime: String?
    public var bytes: Int?
    public var extractedText: String?
    public var externalFileID: String?     // id used to find the file inside an export folder
}

public struct ParsedConversation: Sendable {
    public var externalID: String
    public var title: String?
    public var createdAt: Double?
    public var updatedAt: Double?
    public var messages: [NewMessage]
    public var attachments: [ParsedAttachment] = []
    public var meta: String?
    /// Alternative branches (ChatGPT regenerations/edits) imported as sibling conversations.
    public var branches: [ParsedConversation] = []
}

public protocol ConversationParser: Sendable {
    var sourceKind: String { get }
    /// Called once per top-level conversation object.
    func parse(_ object: [String: Any]) throws -> ParsedConversation?
}

enum JSON {
    static func string(_ v: Any?) -> String? { v as? String }
    static func double(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
    static func array(_ v: Any?) -> [Any]? { v as? [Any] }
    static func encode(_ obj: [String: Any]) -> String? {
        guard !obj.isEmpty, JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
