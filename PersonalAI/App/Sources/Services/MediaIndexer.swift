import Foundation
import Vision
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import PersonalAICore

/// Turns photos and files into searchable rows using only on-device Apple frameworks (Vision, PDFKit, ImageIO).
/// Only identifiers, names, dates, recognised text and labels are stored; the bytes stay in Photos / Files.
enum MediaIndexer {
    struct ImageFacts { var text: String; var labels: [String]; var width: Int; var height: Int; var date: Date?; var lat: Double?; var lon: Double? }

    static func analyze(imageData data: Data) -> ImageFacts {
        var facts = ImageFacts(text: "", labels: [], width: 0, height: 0, date: nil, lat: nil, lon: nil)
        if let src = CGImageSourceCreateWithData(data as CFData, nil), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            facts.width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            facts.height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any], let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let f = DateFormatter(); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
                facts.date = f.date(from: s)
            }
            if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any], var lat = gps[kCGImagePropertyGPSLatitude] as? Double, var lon = gps[kCGImagePropertyGPSLongitude] as? Double {
                if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
                if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = -lon }
                facts.lat = lat; facts.lon = lon
            }
        }
        let ocr = VNRecognizeTextRequest()
        ocr.recognitionLevel = .accurate
        ocr.usesLanguageCorrection = true
        let classify = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(data: data, options: [:])
        try? handler.perform([ocr, classify])
        facts.text = (ocr.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        facts.labels = (classify.results ?? []).filter { $0.confidence > 0.3 }.sorted { $0.confidence > $1.confidence }.prefix(8).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        return facts
    }

    static func indexPhoto(data: Data, identifier: String, name: String?, services s: PersonalAIServices) throws {
        let f = analyze(imageData: data)
        let src = try s.archive.upsertSource(kind: "photos", name: "Photos you chose", externalID: "photos-picker")
        var a = NewAsset(kind: "photo", externalID: identifier, name: name, mime: "image/*", createdAt: f.date?.timeIntervalSince1970)
        a.width = f.width; a.height = f.height; a.latitude = f.lat; a.longitude = f.lon
        a.text = f.text.isEmpty ? nil : f.text
        a.labels = f.labels.isEmpty ? nil : f.labels.joined(separator: ", ")
        a.bytes = data.count
        try s.assets.upsert(sourceID: src, a)
    }

    /// Walks a user-chosen folder. Returns how many files were indexed.
    static func indexFolder(_ folder: URL, services s: PersonalAIServices, isCancelled: () -> Bool, progress: (Int, String) -> Void) throws -> Int {
        let srcID = try s.archive.upsertSource(kind: "files", name: folder.lastPathComponent, externalID: "folder:" + folder.lastPathComponent)
        var seen = Set<String>()
        var n = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey]
        guard let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        for case let url as URL in en {
            if isCancelled() { break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let size = v.fileSize ?? 0
            if size > 40_000_000 { continue }
            let rel = url.path.replacingOccurrences(of: folder.path, with: "")
            let type = v.contentType ?? UTType(filenameExtension: url.pathExtension)
            var asset = NewAsset(kind: "document", externalID: rel, name: url.lastPathComponent, mime: type?.preferredMIMEType, createdAt: v.contentModificationDate?.timeIntervalSince1970)
            asset.bytes = size
            if let t = type, t.conforms(to: .image), let data = try? Data(contentsOf: url) {
                let f = analyze(imageData: data)
                asset.kind = "image"; asset.text = f.text.isEmpty ? nil : f.text; asset.labels = f.labels.joined(separator: ", "); asset.width = f.width; asset.height = f.height
                asset.latitude = f.lat; asset.longitude = f.lon
                if let d = f.date { asset.createdAt = d.timeIntervalSince1970 }
            } else if let t = type, t.conforms(to: .pdf), let doc = PDFDocument(url: url) {
                asset.text = String((doc.string ?? "").prefix(200_000))
            } else if let t = type, t.conforms(to: .text) || t.conforms(to: .json) || ["md", "markdown", "txt", "csv", "rtf"].contains(url.pathExtension.lowercased()) {
                asset.kind = "text"
                if let str = try? String(contentsOf: url, encoding: .utf8) { asset.text = String(str.prefix(200_000)) }
            } else { continue }
            try s.assets.upsert(sourceID: srcID, asset)
            seen.insert(rel); n += 1
            if n % 10 == 0 { progress(n, url.lastPathComponent) }
        }
        if !isCancelled() { _ = try s.assets.markInaccessible(sourceID: srcID, keepingExternalIDs: seen) }
        return n
    }
}
