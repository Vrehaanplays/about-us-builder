import Foundation

/// claude.ai "Export data" conversations.json: [{uuid, name, created_at, chat_messages:[{uuid, sender, text, content, attachments, files}]}]
public struct ClaudeParser: ConversationParser {
    public let sourceKind = "claude_export"
    public init() {}

    public func parse(_ obj: [String: Any]) throws -> ParsedConversation? {
        guard let raw = JSON.array(obj["chat_messages"]) as? [[String: Any]] else { return nil }
        let cid = JSON.string(obj["uuid"]) ?? UUID().uuidString
        let created = ISODate.parse(JSON.string(obj["created_at"]))
        var out: [NewMessage] = []
        var atts: [ParsedAttachment] = []
        var last = created ?? 0
        for m in raw {
            let sender = JSON.string(m["sender"]) ?? "human"
            let role: Role = sender == "assistant" ? .assistant : .user
            var text = ""
            if let blocks = JSON.array(m["content"]) as? [[String: Any]], !blocks.isEmpty {
                for b in blocks where (JSON.string(b["type"]) ?? "text") == "text" {
                    if let t = JSON.string(b["text"]) { text += (text.isEmpty ? "" : "\n") + t }
                }
            }
            if text.isEmpty { text = JSON.string(m["text"]) ?? "" }
            let t = ISODate.parse(JSON.string(m["created_at"])) ?? last
            last = max(last, t)
            let mid = JSON.string(m["uuid"]) ?? "\(cid)#\(out.count)"
            for a in (JSON.array(m["attachments"]) as? [[String: Any]]) ?? [] {
                atts.append(ParsedAttachment(messageExternalID: mid, name: JSON.string(a["file_name"]) ?? "attachment",
                                             mime: JSON.string(a["file_type"]), bytes: (a["file_size"] as? NSNumber)?.intValue,
                                             extractedText: JSON.string(a["extracted_content"]), externalFileID: nil))
            }
            for f in (JSON.array(m["files"]) as? [[String: Any]]) ?? [] {
                atts.append(ParsedAttachment(messageExternalID: mid, name: JSON.string(f["file_name"]) ?? "file", mime: nil, bytes: nil,
                                             extractedText: nil, externalFileID: JSON.string(f["file_uuid"])))
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && !atts.contains(where: { $0.messageExternalID == mid }) { continue }
            out.append(NewMessage(role: role, text: trimmed.isEmpty ? "[attachment]" : trimmed, createdAt: t, externalID: mid,
                                  locality: .imported, meta: nil))
        }
        if out.isEmpty { return nil }
        return ParsedConversation(externalID: cid, title: JSON.string(obj["name"]), createdAt: created,
                                  updatedAt: ISODate.parse(JSON.string(obj["updated_at"])), messages: out, attachments: atts,
                                  meta: JSON.encode(["format": "claude"]))
    }
}
