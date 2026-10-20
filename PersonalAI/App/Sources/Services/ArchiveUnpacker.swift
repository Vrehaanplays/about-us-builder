import Foundation
import ZIPFoundation

/// Turns whatever the user picked (a conversations.json, a whole export folder, or the .zip ChatGPT/Claude emails you) into something the importer accepts.
enum ArchiveUnpacker {
    /// Returns the item to import and, when something was extracted, the temp directory to delete afterwards.
    static func prepare(_ url: URL) throws -> (URL, URL?) {
        if url.pathExtension.lowercased() == "zip" {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: url, to: tmp)
            // exports are either flat or wrapped in one folder
            if FileManager.default.fileExists(atPath: tmp.appendingPathComponent("conversations.json").path) { return (tmp, tmp) }
            let kids = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
            if let inner = kids.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("conversations.json").path) }) { return (inner, tmp) }
            return (tmp, tmp)
        }
        return (url, nil)
    }
}
