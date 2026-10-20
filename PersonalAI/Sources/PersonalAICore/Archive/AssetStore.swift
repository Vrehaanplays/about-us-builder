import Foundation

public struct AssetRecord: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var sourceID: Int64
    public var kind: String
    public var externalID: String
    public var name: String?
    public var mime: String?
    public var createdAt: Double?
    public var width: Int?, height: Int?
    public var latitude: Double?, longitude: Double?
    public var place: String?
    public var text: String?
    public var caption: String?
    public var labels: String?
    public var status: String
    static let columns = "id, source_id, kind, external_id, name, mime, created_at, width, height, latitude, longitude, place, text, caption, labels, status"
    init(row r: Row) {
        id = r.int(0); sourceID = r.int(1); kind = r.text(2); externalID = r.text(3); name = r.optText(4); mime = r.optText(5)
        createdAt = r.optDouble(6); width = r.optInt(7).map(Int.init); height = r.optInt(8).map(Int.init)
        latitude = r.optDouble(9); longitude = r.optDouble(10); place = r.optText(11)
        text = r.optText(12); caption = r.optText(13); labels = r.optText(14); status = r.text(15)
    }
}

public struct NewAsset: Sendable {
    public var kind: String, externalID: String
    public var name: String?, mime: String?
    public var createdAt: Double?
    public var width: Int?, height: Int?
    public var latitude: Double?, longitude: Double?, place: String?
    public var text: String?, caption: String?, labels: String?
    public var bytes: Int?
    public var status = "indexed"
    public var meta: String?
    public init(kind: String, externalID: String, name: String? = nil, mime: String? = nil, createdAt: Double? = nil) {
        self.kind = kind; self.externalID = externalID; self.name = name; self.mime = mime; self.createdAt = createdAt
    }
}

/// Photos, files and export attachments. Only identifiers and extracted text are stored here; the
/// bytes stay where iOS keeps them (Photos library / Files) and are re-opened through the platform API.
public final class AssetStore: @unchecked Sendable {
    public let db: ArchiveDatabase
    public init(db: ArchiveDatabase) { self.db = db }

    @discardableResult
    public func upsert(sourceID: Int64, _ a: NewAsset) throws -> Int64 {
        try db.write { w in
            try w.transaction {
                if let id = try w.queryOne("SELECT id FROM asset WHERE source_id=? AND external_id=?", [.int(sourceID), .text(a.externalID)], { $0.int(0) }) {
                    try w.run("""
                        UPDATE asset SET name=COALESCE(?,name), mime=COALESCE(?,mime), created_at=COALESCE(?,created_at),
                          width=COALESCE(?,width), height=COALESCE(?,height), latitude=COALESCE(?,latitude), longitude=COALESCE(?,longitude),
                          place=COALESCE(?,place), text=COALESCE(?,text), caption=COALESCE(?,caption), labels=COALESCE(?,labels),
                          bytes=COALESCE(?,bytes), status=?, meta=COALESCE(?,meta) WHERE id=?
                        """, [.opt(a.name), .opt(a.mime), .opt(a.createdAt), .opt(a.width), .opt(a.height), .opt(a.latitude), .opt(a.longitude),
                              .opt(a.place), .opt(a.text), .opt(a.caption), .opt(a.labels), .opt(a.bytes), .text(a.status), .opt(a.meta), .int(id)])
                    return id
                }
                try w.run("""
                    INSERT INTO asset(source_id,kind,external_id,name,mime,created_at,added_at,width,height,latitude,longitude,place,text,caption,labels,bytes,status,meta)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [.int(sourceID), .text(a.kind), .text(a.externalID), .opt(a.name), .opt(a.mime), .opt(a.createdAt), .double(Clock.now()),
                          .opt(a.width), .opt(a.height), .opt(a.latitude), .opt(a.longitude), .opt(a.place), .opt(a.text), .opt(a.caption),
                          .opt(a.labels), .opt(a.bytes), .text(a.status), .opt(a.meta)])
                return w.lastInsertRowID
            }
        }
    }

    public func link(assetID: Int64, messageID: Int64, conversationID: Int64, kind: String, score: Double = 1) throws {
        try db.write { try $0.run("INSERT OR REPLACE INTO asset_link(asset_id,message_id,conversation_id,kind,score) VALUES(?,?,?,?,?)",
                                  [.int(assetID), .int(messageID), .int(conversationID), .text(kind), .double(score)]) }
    }

    public func asset(_ id: Int64) throws -> AssetRecord? {
        try db.read { try $0.queryOne("SELECT \(AssetRecord.columns) FROM asset WHERE id=?", [.int(id)], AssetRecord.init(row:)) }
    }

    public func assets(linkedTo messageIDs: [Int64]) throws -> [AssetRecord] {
        guard !messageIDs.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: messageIDs.count).joined(separator: ",")
        return try db.read { try $0.query("""
            SELECT \(AssetRecord.columns) FROM asset WHERE id IN (SELECT asset_id FROM asset_link WHERE message_id IN (\(marks)))
            """, messageIDs.map { .int($0) }, AssetRecord.init(row:)) }
    }

    /// Photos taken within `window` seconds of a message, for "the photo I sent around then" (kind = time_near, weaker than attached).
    public func assetsNear(time: Double, window: Double = 1800, limit: Int = 10) throws -> [AssetRecord] {
        try db.read { try $0.query("""
            SELECT \(AssetRecord.columns) FROM asset WHERE kind IN ('photo','image') AND status='indexed' AND created_at BETWEEN ? AND ?
            ORDER BY ABS(created_at - ?) LIMIT ?
            """, [.double(time - window), .double(time + window), .double(time), .int(limit)], AssetRecord.init(row:)) }
    }

    public func markInaccessible(sourceID: Int64, keepingExternalIDs: Set<String>) throws -> Int {
        // Permission was revoked or assets were deleted: keep the derived text but never claim the asset is openable.
        try db.write { w in
            let all = try w.query("SELECT id, external_id FROM asset WHERE source_id=? AND status='indexed'", [.int(sourceID)]) { ($0.int(0), $0.text(1)) }
            var n = 0
            for (id, ext) in all where !keepingExternalIDs.contains(ext) {
                try w.run("UPDATE asset SET status='inaccessible' WHERE id=?", [.int(id)]); n += 1
            }
            return n
        }
    }
}
