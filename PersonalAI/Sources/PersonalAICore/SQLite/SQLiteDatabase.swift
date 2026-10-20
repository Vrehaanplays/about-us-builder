import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)
    case misuse(String)
    public var description: String {
        switch self {
        case .open(let m): return "SQLite open failed: \(m)"
        case .prepare(let m, let s): return "SQLite prepare failed: \(m) [\(s.prefix(120))]"
        case .step(let m, let s): return "SQLite step failed: \(m) [\(s.prefix(120))]"
        case .misuse(let m): return "SQLite misuse: \(m)"
        }
    }
}

public enum SQLiteValue: Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

extension SQLiteValue: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral {
    public init(integerLiteral v: Int64) { self = .int(v) }
    public init(stringLiteral v: String) { self = .text(v) }
    public init(floatLiteral v: Double) { self = .double(v) }
    public init(nilLiteral: ()) { self = .null }
}

public extension SQLiteValue {
    static func opt(_ v: Int64?) -> SQLiteValue { v.map { .int($0) } ?? .null }
    static func opt(_ v: Int?) -> SQLiteValue { v.map { .int(Int64($0)) } ?? .null }
    static func opt(_ v: Double?) -> SQLiteValue { v.map { .double($0) } ?? .null }
    static func opt(_ v: String?) -> SQLiteValue { v.map { .text($0) } ?? .null }
    static func int(_ v: Int) -> SQLiteValue { .int(Int64(v)) }
    static func bool(_ v: Bool) -> SQLiteValue { .int(v ? 1 : 0) }
}

/// A read-only view of the current result row. Valid only inside the query callback.
public struct Row {
    let stmt: OpaquePointer
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
    public func optText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
    public func optInt(_ i: Int32) -> Int64? { isNull(i) ? nil : int(i) }
    public func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
    public func blob(_ i: Int32) -> Data {
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: n)
    }
    /// Zero-copy access to a BLOB column; the buffer is only valid inside `body`.
    public func withBlob<R>(_ i: Int32, _ body: (UnsafeRawBufferPointer) -> R) -> R {
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return body(UnsafeRawBufferPointer(start: nil, count: 0)) }
        return body(UnsafeRawBufferPointer(start: p, count: n))
    }
}

/// Thin, dependency-free SQLite wrapper. One instance == one connection, guarded by a lock.
/// Prepared statements are cached per SQL string (hot paths: import, search, vector scans).
public final class SQLiteDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var cache: [String: OpaquePointer] = [:]
    public let path: String
    public let readOnly: Bool
    private var txDepth = 0

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        self.readOnly = readOnly
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_FULLMUTEX
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let h = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError.open(msg)
        }
        db = h
        sqlite3_busy_timeout(h, 10_000)
    }

    deinit {
        for (_, s) in cache { sqlite3_finalize(s) }
        if let db { sqlite3_close_v2(db) }
    }

    public var lastInsertRowID: Int64 { lock.withLock { sqlite3_last_insert_rowid(db) } }
    public var changes: Int { lock.withLock { Int(sqlite3_changes(db)) } }

    public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func errorMessage() -> String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed" }

    private func statement(_ sql: String) throws -> OpaquePointer {
        if let s = cache[sql] { return s }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw SQLiteError.prepare(errorMessage(), sql: sql)
        }
        if cache.count > 256 { for (_, v) in cache { sqlite3_finalize(v) }; cache.removeAll() }
        cache[sql] = s
        return s
    }

    private func bind(_ stmt: OpaquePointer, _ params: [SQLiteValue]) {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .blob(let d):
                if d.isEmpty { sqlite3_bind_zeroblob(stmt, idx, 0) }
                else { d.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), Self.transient) } }
            }
        }
    }

    /// Execute one or more statements with no parameters/results (DDL, PRAGMA, batches).
    public func exec(_ sql: String) throws {
        try lock.withLock {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let m = err.map { String(cString: $0) } ?? errorMessage()
                sqlite3_free(err)
                throw SQLiteError.step(m, sql: sql)
            }
        }
    }

    @discardableResult
    public func run(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int {
        try lock.withLock {
            let s = try statement(sql)
            bind(s, params)
            let rc = sqlite3_step(s)
            sqlite3_reset(s)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError.step(errorMessage(), sql: sql) }
            return Int(sqlite3_changes(db))
        }
    }

    /// Streams rows to `each`; return `false` from the callback to stop early.
    public func forEach(_ sql: String, _ params: [SQLiteValue] = [], _ each: (Row) throws -> Bool) throws {
        try lock.withLock {
            let s = try statement(sql)
            bind(s, params)
            defer { sqlite3_reset(s) }
            while true {
                let rc = sqlite3_step(s)
                if rc == SQLITE_ROW {
                    if try !each(Row(stmt: s)) { break }
                } else if rc == SQLITE_DONE { break }
                else { throw SQLiteError.step(errorMessage(), sql: sql) }
            }
        }
    }

    public func query<T>(_ sql: String, _ params: [SQLiteValue] = [], _ map: (Row) throws -> T) throws -> [T] {
        var out: [T] = []
        try forEach(sql, params) { out.append(try map($0)); return true }
        return out
    }

    public func queryOne<T>(_ sql: String, _ params: [SQLiteValue] = [], _ map: (Row) throws -> T) throws -> T? {
        var out: T?
        try forEach(sql, params) { out = try map($0); return false }
        return out
    }

    public func scalarInt(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int64 {
        try queryOne(sql, params) { $0.int(0) } ?? 0
    }

    /// Nested calls join the outer transaction (savepoint-free: any throw rolls the outermost back).
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            if txDepth > 0 { return try body() }
            try exec("BEGIN IMMEDIATE")
            txDepth = 1
            defer { txDepth = 0 }
            do {
                let r = try body()
                try exec("COMMIT")
                return r
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    public func checkpoint() { lock.withLock { _ = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil) } }
    public func interrupt() { if let db { sqlite3_interrupt(db) } }

    /// Applied to every connection. WAL lets the UI/retrieval read while the indexer writes.
    public func applyPerformancePragmas(cacheMB: Int, mmapMB: Int) throws {
        try exec("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        PRAGMA temp_store=MEMORY;
        PRAGMA cache_size=-\(cacheMB * 1024);
        PRAGMA mmap_size=\(mmapMB * 1024 * 1024);
        PRAGMA foreign_keys=ON;
        PRAGMA wal_autocheckpoint=4000;
        """)
    }
}
