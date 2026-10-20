import Foundation

public struct ImportProgress: Sendable {
    public var conversations: Int
    public var messages: Int
    public var fraction: Double      // by bytes consumed
}

public enum ImportError: Error, CustomStringConvertible {
    case unsupported(String)
    case cancelled
    public var description: String {
        switch self {
        case .unsupported(let s): return "Unsupported import: \(s)"
        case .cancelled: return "Import cancelled (completed conversations were kept; re-run to continue)"
        }
    }
}

/// Imports conversation archives. Safe to run repeatedly: dedupe is per message, so re-importing an updated
/// export adds only what is new, and an interrupted import resumes by simply running again.
public final class ImportCoordinator: @unchecked Sendable {
    public let store: ArchiveStore
    public let assets: AssetStore
    public init(store: ArchiveStore) { self.store = store; self.assets = AssetStore(db: store.db) }

    /// `url` may be a conversations.json, a .jsonl, a .md/.txt note, or an export folder containing conversations.json.
    public func importItem(at url: URL, progress: (@Sendable (ImportProgress) -> Void)? = nil,
                           isCancelled: @Sendable () -> Bool = { false }) throws -> ImportReport {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let json = url.appendingPathComponent("conversations.json")
            guard FileManager.default.fileExists(atPath: json.path) else { throw ImportError.unsupported("no conversations.json in folder") }
            var report = try importConversationsJSON(json, exportRoot: url, progress: progress, isCancelled: isCancelled)
            report.warnings.append(contentsOf: [])
            return report
        }
        switch url.pathExtension.lowercased() {
        case "json": return try importConversationsJSON(url, exportRoot: url.deletingLastPathComponent(), progress: progress, isCancelled: isCancelled)
        case "jsonl", "ndjson": return try importJSONL(url, progress: progress, isCancelled: isCancelled)
        case "md", "markdown", "txt", "text": return try importNote(url)
        default: throw ImportError.unsupported(url.lastPathComponent)
        }
    }

    // MARK: conversations.json (ChatGPT or Claude, sniffed)

    private func importConversationsJSON(_ url: URL, exportRoot: URL, progress: (@Sendable (ImportProgress) -> Void)?,
                                         isCancelled: @Sendable () -> Bool) throws -> ImportReport {
        let started = Date()
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var parser: (any ConversationParser)?
        var report = ImportReport()
        var sourceID: Int64 = 0
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fingerprint = "\(data.count):\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        var bytesSeen = 0
        var lastReport = Date.distantPast

        try JSONArrayStreamer.forEachElement(in: data) { elementData in
            if isCancelled() { throw ImportError.cancelled }
            bytesSeen += elementData.count
            guard let obj = try JSONSerialization.jsonObject(with: elementData) as? [String: Any] else { report.skipped += 1; return true }
            if parser == nil {
                if obj["mapping"] != nil { parser = ChatGPTParser() }
                else if obj["chat_messages"] != nil { parser = ClaudeParser() }
                else { throw ImportError.unsupported("unrecognised conversations.json schema (keys: \(obj.keys.sorted().prefix(8).joined(separator: ", ")))") }
                sourceID = try store.upsertSource(kind: parser!.sourceKind, name: url.deletingLastPathComponent().lastPathComponent,
                                                  externalID: exportRoot.lastPathComponent, fingerprint: fingerprint)
            }
            report.conversationsSeen += 1
            guard let parsed = try parser!.parse(obj) else { report.skipped += 1; return true }
            try persist(parsed, sourceID: sourceID, exportRoot: exportRoot, report: &report)
            for b in parsed.branches { try persist(b, sourceID: sourceID, exportRoot: exportRoot, report: &report) }
            if let progress, Date().timeIntervalSince(lastReport) > 0.2 {
                lastReport = Date()
                progress(ImportProgress(conversations: report.conversationsSeen, messages: report.messagesInserted,
                                        fraction: Double(bytesSeen) / Double(max(1, data.count))))
            }
            return true
        }
        progress?(ImportProgress(conversations: report.conversationsSeen, messages: report.messagesInserted, fraction: 1))
        report.elapsed = Date().timeIntervalSince(started)
        return report
    }

    private func persist(_ p: ParsedConversation, sourceID: Int64, exportRoot: URL, report: inout ImportReport) throws {
        let (cid, isNew) = try store.upsertConversation(sourceID: sourceID, externalID: p.externalID, title: p.title,
                                                         createdAt: p.createdAt, updatedAt: p.updatedAt, meta: p.meta)
        if isNew { report.conversationsNew += 1 }
        let r = try store.appendMessages(conversationID: cid, p.messages)
        report.messagesInserted += r.inserted
        report.messagesDuplicate += r.duplicates
        if !p.attachments.isEmpty { try persistAttachments(p, conversationID: cid, sourceID: sourceID, exportRoot: exportRoot) }
    }

    private func persistAttachments(_ p: ParsedConversation, conversationID: Int64, sourceID: Int64, exportRoot: URL) throws {
        let ids = try store.db.read { db in
            try db.query("SELECT external_id, id FROM message WHERE conversation_id=? AND external_id IS NOT NULL", [.int(conversationID)]) { ($0.text(0), $0.int(1)) }
        }
        let byExternal = Dictionary(ids, uniquingKeysWith: { a, _ in a })
        for a in p.attachments {
            guard let mid = byExternal[a.messageExternalID] else { continue }
            var na = NewAsset(kind: (a.mime ?? "").hasPrefix("image/") ? "image" : "document",
                              externalID: "\(a.messageExternalID):\(a.externalFileID ?? a.name)", name: a.name, mime: a.mime)
            na.text = a.extractedText
            na.bytes = a.bytes
            if let fid = a.externalFileID, let f = Self.findFile(withIDPrefix: fid, in: exportRoot) {
                na.meta = JSON.encode(["relative_path": f.path.replacingOccurrences(of: exportRoot.path + "/", with: "")])
                if na.mime == nil { na.mime = Self.mime(for: f.pathExtension) }
                if na.kind == "document", (na.mime ?? "").hasPrefix("image/") { na.kind = "image" }
            } else if a.extractedText == nil && a.externalFileID != nil {
                na.status = "inaccessible"   // referenced by the export but the file was not included
            }
            na.createdAt = (try? store.message(mid))?.createdAt
            let aid = try assets.upsert(sourceID: sourceID, na)
            try assets.link(assetID: aid, messageID: mid, conversationID: conversationID, kind: "attached")
        }
    }

    static func findFile(withIDPrefix id: String, in root: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        if let hit = items.first(where: { $0.hasPrefix(id) }) { return root.appendingPathComponent(hit) }
        return nil
    }

    static func mime(for ext: String) -> String? {
        switch ext.lowercased() {
        case "png": return "image/png"; case "jpg", "jpeg": return "image/jpeg"; case "heic": return "image/heic"
        case "gif": return "image/gif"; case "webp": return "image/webp"; case "pdf": return "application/pdf"
        case "txt", "md": return "text/plain"; default: return nil
        }
    }

    // MARK: JSONL: {"conversation":"id","role":"user","content":"...","timestamp":...}

    private func importJSONL(_ url: URL, progress: (@Sendable (ImportProgress) -> Void)?, isCancelled: @Sendable () -> Bool) throws -> ImportReport {
        let started = Date()
        var report = ImportReport()
        let sourceID = try store.upsertSource(kind: "generic", name: url.lastPathComponent, externalID: url.lastPathComponent)
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var groups: [String: [NewMessage]] = [:]
        var order: [String] = []
        var n = 0
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            if isCancelled() { throw ImportError.cancelled }
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { report.skipped += 1; continue }
            let conv = JSON.string(o["conversation"]) ?? JSON.string(o["conversation_id"]) ?? JSON.string(o["session"]) ?? "default"
            let roleStr = (JSON.string(o["role"]) ?? JSON.string(o["author"]) ?? "user").lowercased()
            let role: Role = roleStr == "assistant" || roleStr == "ai" || roleStr == "model" ? .assistant : (roleStr == "system" ? .system : .user)
            let text = JSON.string(o["content"]) ?? JSON.string(o["text"]) ?? JSON.string(o["message"]) ?? ""
            if text.isEmpty { report.skipped += 1; continue }
            let t = JSON.double(o["timestamp"]) ?? JSON.double(o["created_at"]) ?? ISODate.parse(JSON.string(o["timestamp"]) ?? JSON.string(o["created_at"])) ?? started.timeIntervalSince1970 + Double(n)
            if groups[conv] == nil { order.append(conv) }
            groups[conv, default: []].append(NewMessage(role: role, text: text, createdAt: t, externalID: JSON.string(o["id"])))
            n += 1
        }
        for conv in order {
            let msgs = groups[conv]!.sorted { $0.createdAt < $1.createdAt }
            let (cid, isNew) = try store.upsertConversation(sourceID: sourceID, externalID: conv, title: conv == "default" ? url.deletingPathExtension().lastPathComponent : conv,
                                                             createdAt: msgs.first?.createdAt, updatedAt: msgs.last?.createdAt)
            report.conversationsSeen += 1; if isNew { report.conversationsNew += 1 }
            let r = try store.appendMessages(conversationID: cid, msgs)
            report.messagesInserted += r.inserted; report.messagesDuplicate += r.duplicates
        }
        report.elapsed = Date().timeIntervalSince(started)
        return report
    }

    // MARK: notes (markdown / text): one conversation, one user-authored message; the chunker slices it for retrieval

    private func importNote(_ url: URL) throws -> ImportReport {
        let started = Date()
        var report = ImportReport()
        let text = try String(contentsOf: url, encoding: .utf8)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let created = (attrs?[.creationDate] as? Date)?.timeIntervalSince1970 ?? started.timeIntervalSince1970
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? created
        let sourceID = try store.upsertSource(kind: "note", name: url.lastPathComponent, externalID: url.lastPathComponent)
        let (cid, isNew) = try store.upsertConversation(sourceID: sourceID, externalID: url.lastPathComponent, title: url.deletingPathExtension().lastPathComponent,
                                                         createdAt: created, updatedAt: modified)
        report.conversationsSeen = 1; if isNew { report.conversationsNew = 1 }
        let r = try store.appendMessages(conversationID: cid, [NewMessage(role: .user, text: text, createdAt: modified, meta: JSON.encode(["note": true]))])
        report.messagesInserted = r.inserted; report.messagesDuplicate = r.duplicates
        report.elapsed = Date().timeIntervalSince(started)
        return report
    }
}
