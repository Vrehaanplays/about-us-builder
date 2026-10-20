import Foundation

/// OpenAI "Export data" conversations.json. Conversations are trees (edits/regenerations make branches);
/// the visible thread is the path from `current_node` to the root. Other branches are kept as sibling
/// conversations containing only their divergent suffix, so nothing the user ever saw is lost.
public struct ChatGPTParser: ConversationParser {
    public let sourceKind = "chatgpt_export"
    public var keepHidden = false
    public var maxBranchesPerConversation = 24
    public init(keepHidden: Bool = false) { self.keepHidden = keepHidden }

    public func parse(_ obj: [String: Any]) throws -> ParsedConversation? {
        guard let mapping = JSON.dict(obj["mapping"]) as? [String: [String: Any]] ?? nil else { return nil }
        let cid = JSON.string(obj["conversation_id"]) ?? JSON.string(obj["id"]) ?? UUID().uuidString
        let created = JSON.double(obj["create_time"])
        let updated = JSON.double(obj["update_time"])

        var mainPath: [String] = []
        var cursor = JSON.string(obj["current_node"])
        if cursor == nil || mapping[cursor!] == nil {
            // fall back: longest chain via first children from the root
            if let root = mapping.first(where: { JSON.string($0.value["parent"]) == nil })?.key {
                var n: String? = root
                var chain: [String] = []
                while let k = n, let node = mapping[k] {
                    chain.append(k)
                    n = (JSON.array(node["children"]) as? [String])?.last
                }
                cursor = chain.last
            }
        }
        var seen = Set<String>()
        while let k = cursor, let node = mapping[k], !seen.contains(k) {
            seen.insert(k); mainPath.append(k)
            cursor = JSON.string(node["parent"])
        }
        mainPath.reverse()

        var attachments: [ParsedAttachment] = []
        let msgs = convert(path: mainPath, mapping: mapping, fallbackTime: created ?? 0, attachments: &attachments)
        if msgs.isEmpty && attachments.isEmpty { return nil }

        var result = ParsedConversation(externalID: cid, title: JSON.string(obj["title"]), createdAt: created, updatedAt: updated,
                                        messages: msgs, attachments: attachments,
                                        meta: JSON.encode(["format": "chatgpt", "default_model": JSON.string(obj["default_model_slug"]) as Any].compactMapValues { $0 }))

        // Alternative branches
        let mainSet = Set(mainPath)
        var branchCount = 0
        for k in mainPath {
            guard let kids = JSON.array(mapping[k]?["children"]) as? [String] else { continue }
            for child in kids where !mainSet.contains(child) {
                guard branchCount < maxBranchesPerConversation else { break }
                var chain: [String] = []
                var n: String? = child
                var guardSet = Set<String>()
                while let x = n, let node = mapping[x], !guardSet.contains(x) {
                    guardSet.insert(x); chain.append(x)
                    n = (JSON.array(node["children"]) as? [String])?.last
                }
                var batt: [ParsedAttachment] = []
                let bm = convert(path: chain, mapping: mapping, fallbackTime: created ?? 0, attachments: &batt)
                if bm.isEmpty { continue }
                branchCount += 1
                var b = ParsedConversation(externalID: "\(cid)#branch:\(child)", title: (result.title ?? "Untitled") + " (alternate branch)",
                                           createdAt: bm.first?.createdAt, updatedAt: bm.last?.createdAt, messages: bm, attachments: batt,
                                           meta: JSON.encode(["format": "chatgpt", "branch_of": cid, "fork_after_node": k]))
                b.branches = []
                result.branches.append(b)
            }
        }
        return result
    }

    private func convert(path: [String], mapping: [String: [String: Any]], fallbackTime: Double,
                         attachments: inout [ParsedAttachment]) -> [NewMessage] {
        var out: [NewMessage] = []
        var lastTime = fallbackTime
        for key in path {
            guard let node = mapping[key], let m = JSON.dict(node["message"]) else { continue }
            let author = JSON.dict(m["author"])
            let roleStr = JSON.string(author?["role"]) ?? "user"
            guard let role = Role(rawValue: roleStr) else { continue }
            let metadata = JSON.dict(m["metadata"]) ?? [:]
            if !keepHidden, (metadata["is_visually_hidden_from_conversation"] as? Bool) == true { continue }
            if !keepHidden, role == .system, (JSON.string(m["recipient"]) ?? "all") != "all" { continue }
            let content = JSON.dict(m["content"]) ?? [:]
            let kind = JSON.string(content["content_type"]) ?? "text"
            var text = ""
            var assetRefs: [String] = []
            switch kind {
            case "text", "multimodal_text":
                for part in JSON.array(content["parts"]) ?? [] {
                    if let s = part as? String { text += (text.isEmpty ? "" : "\n") + s }
                    else if let d = part as? [String: Any] {
                        if let ptr = JSON.string(d["asset_pointer"]) {
                            assetRefs.append(ptr.replacingOccurrences(of: "file-service://", with: "").replacingOccurrences(of: "sediment://", with: ""))
                        }
                        if let t = JSON.string(d["text"]) { text += (text.isEmpty ? "" : "\n") + t }
                    }
                }
            case "code":
                let lang = JSON.string(content["language"]) ?? ""
                if let t = JSON.string(content["text"]) { text = "```\(lang == "unknown" ? "" : lang)\n\(t)\n```" }
            case "execution_output", "tether_quote", "tether_browsing_display":
                text = JSON.string(content["text"]) ?? ""
            default:
                continue   // reasoning traces and other internal content types are not conversation text
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let atts = (JSON.array(metadata["attachments"]) as? [[String: Any]]) ?? []
            if trimmed.isEmpty && assetRefs.isEmpty && atts.isEmpty { continue }
            var t = JSON.double(m["create_time"]) ?? JSON.double(node["create_time"])
            if t == nil { t = lastTime }
            lastTime = max(lastTime, t!)
            let mid = JSON.string(m["id"]) ?? key
            var meta: [String: Any] = [:]
            if !assetRefs.isEmpty { meta["asset_refs"] = assetRefs }
            if kind != "text" { meta["content_type"] = kind }
            for a in atts {
                let fid = JSON.string(a["id"])
                attachments.append(ParsedAttachment(messageExternalID: mid, name: JSON.string(a["name"]) ?? fid ?? "attachment",
                                                    mime: JSON.string(a["mime_type"]), bytes: (a["size"] as? NSNumber)?.intValue,
                                                    extractedText: nil, externalFileID: fid))
            }
            for ref in assetRefs {
                attachments.append(ParsedAttachment(messageExternalID: mid, name: ref, mime: nil, bytes: nil, extractedText: nil, externalFileID: ref))
            }
            out.append(NewMessage(role: role, text: trimmed.isEmpty ? "[attachment]" : trimmed, createdAt: t!, externalID: mid,
                                  model: JSON.string(metadata["model_slug"]), locality: .imported, meta: JSON.encode(meta)))
        }
        return out
    }
}
