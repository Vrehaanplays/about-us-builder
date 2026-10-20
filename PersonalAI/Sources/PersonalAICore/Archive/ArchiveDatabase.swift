import Foundation

/// One writer + a small pool of readers over the same WAL database file.
/// UI/retrieval reads never wait on the indexer's write transactions.
public final class ArchiveDatabase: @unchecked Sendable {
    public let writer: SQLiteDatabase
    private let readers: [SQLiteDatabase]
    private let pickLock = NSLock()
    private var next = 0
    public let path: String

    public struct Profile: Sendable {
        public var writerCacheMB: Int
        public var readerCacheMB: Int
        public var mmapMB: Int
        public var readerCount: Int
        /// Conservative defaults for an 8 GB phone shared with a ~3 GB model: the page cache is tiny
        /// compared with the model, so SQLite stays in the low hundreds of MB.
        public static let phone = Profile(writerCacheMB: 48, readerCacheMB: 32, mmapMB: 256, readerCount: 2)
        public static let desktop = Profile(writerCacheMB: 256, readerCacheMB: 128, mmapMB: 2048, readerCount: 3)
        public init(writerCacheMB: Int, readerCacheMB: Int, mmapMB: Int, readerCount: Int) {
            self.writerCacheMB = writerCacheMB; self.readerCacheMB = readerCacheMB
            self.mmapMB = mmapMB; self.readerCount = readerCount
        }
    }

    public init(path: String, profile: Profile = .phone) throws {
        self.path = path
        writer = try SQLiteDatabase(path: path)
        try writer.applyPerformancePragmas(cacheMB: profile.writerCacheMB, mmapMB: profile.mmapMB)
        try Schema.migrate(writer)
        var rs: [SQLiteDatabase] = []
        for _ in 0..<max(1, profile.readerCount) {
            let r = try SQLiteDatabase(path: path, readOnly: true)
            try r.exec("PRAGMA cache_size=-\(profile.readerCacheMB * 1024); PRAGMA mmap_size=\(profile.mmapMB * 1024 * 1024); PRAGMA temp_store=MEMORY; PRAGMA query_only=ON;")
            rs.append(r)
        }
        readers = rs
    }

    public func read<T>(_ body: (SQLiteDatabase) throws -> T) rethrows -> T {
        pickLock.lock()
        let r = readers[next % readers.count]
        next &+= 1
        pickLock.unlock()
        return try r.withLock { try body(r) }
    }

    public func write<T>(_ body: (SQLiteDatabase) throws -> T) rethrows -> T {
        try writer.withLock { try body(writer) }
    }

    public func fileSize() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            if let a = try? fm.attributesOfItem(atPath: path + suffix), let s = a[.size] as? NSNumber { total += s.int64Value }
        }
        return total
    }

    public func kvGet(_ key: String) -> String? {
        try? read { try $0.queryOne("SELECT value FROM kv WHERE key=?", [.text(key)]) { $0.text(0) } }
    }
    public func kvSet(_ key: String, _ value: String) {
        _ = try? write { try $0.run("INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)]) }
    }
}
