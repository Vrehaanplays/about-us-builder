import Foundation

// MARK: - Transport & ledger

/// Everything the app sends over the network goes through an `HTTPTransport`, and every request is written to the `NetworkLedger`
/// (host + purpose + byte counts, never conversation content), which the Privacy screen displays.
public protocol HTTPTransport: Sendable {
    func getJSON(_ url: URL, headers: [String: String]) async throws -> Data
    /// Appends the body to `file`, starting at byte `offset` when the server honours the Range header. Returns total bytes now in `file`.
    /// Must throw `CancellationError` promptly when the task is cancelled, leaving the bytes written so far on disk.
    func download(_ url: URL, to file: URL, resumeFrom offset: Int64, headers: [String: String], progress: @Sendable @escaping (Int64) -> Void) async throws -> Int64
}

public struct NetworkLedgerEntry: Sendable, Codable, Identifiable {
    public var id = UUID()
    public var at: Date
    public var host: String
    public var purpose: String
    public var bytes: Int64
}

public final class NetworkLedger: @unchecked Sendable {
    public static let shared = NetworkLedger()
    private let lock = NSLock()
    private var entries: [NetworkLedgerEntry] = []
    public init() {}
    public func record(host: String, purpose: String, bytes: Int64 = 0) { lock.withLock { entries.append(NetworkLedgerEntry(at: Date(), host: host, purpose: purpose, bytes: bytes)); if entries.count > 2000 { entries.removeFirst(500) } } }
    public var all: [NetworkLedgerEntry] { lock.withLock { entries } }
    public var hosts: Set<String> { lock.withLock { Set(entries.map(\.host)) } }
}

/// Hosts the app is allowed to contact for model files. Anything else is refused before a socket is opened.
public enum NetworkPolicy {
    public static let modelHosts: [String] = ["huggingface.co", "hf.co", "xethub.hf.co", "cdn-lfs.huggingface.co", "cas-bridge.xethub.hf.co"]
    public static func isAllowedModelHost(_ host: String) -> Bool { modelHosts.contains { host == $0 || host.hasSuffix("." + $0) } }
}

// MARK: - Plan

public struct RemoteFile: Sendable, Codable, Hashable {
    public var path: String
    public var size: Int64
    public var sha256: String?       // present for LFS files
}

public struct DownloadPlan: Sendable, Codable {
    public var modelID: String
    public var revision: String
    public var files: [RemoteFile]
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

public enum ModelState: Sendable, Equatable {
    case notInstalled
    case planning
    case downloading(received: Int64, total: Int64, file: String)
    case paused(received: Int64, total: Int64)
    case verifying(file: String)
    case installed(bytes: Int64)
    case failed(String)
}

public enum ModelStoreError: Error, LocalizedError, Sendable {
    case invalidID, notEnoughSpace(needed: Int64, available: Int64), checksumMismatch(String), sizeMismatch(String), hostNotAllowed(String), emptyPlan
    public var errorDescription: String? {
        switch self {
        case .invalidID: return "That model id is not valid."
        case .notEnoughSpace(let n, let a): return "Not enough free space: needs \(Self.fmt(n)), \(Self.fmt(a)) available."
        case .checksumMismatch(let f): return "\(f) failed its integrity check and was discarded. Try again."
        case .sizeMismatch(let f): return "\(f) has the wrong size and was discarded. Try again."
        case .hostNotAllowed(let h): return "Blocked a connection to \(h): only the model host is allowed."
        case .emptyPlan: return "The model repository has no downloadable weight files."
        }
    }
    static func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}

/// Downloads, verifies, lists and removes models on disk. All state lives in files, so it survives the app being killed mid-download:
/// each file streams into `<name>.part`, resumes with a Range request, and is renamed into place only after size + SHA-256 checks.
public actor ModelStore {
    public let root: URL
    private let transport: HTTPTransport
    private let ledger: NetworkLedger
    private let freeSpace: @Sendable () -> Int64
    private var tasks: [String: Task<Void, Never>] = [:]
    private var states: [String: ModelState] = [:]
    private var observers: [UUID: @Sendable (String, ModelState) -> Void] = [:]
    public static let weightPatterns = ["safetensors", "json", "jinja", "txt", "model", "tiktoken"]

    public init(root: URL, transport: HTTPTransport, ledger: NetworkLedger = .shared, freeSpace: @escaping @Sendable () -> Int64 = { Int64.max }) {
        self.root = root; self.transport = transport; self.ledger = ledger; self.freeSpace = freeSpace
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: observation
    public func observe(_ f: @escaping @Sendable (String, ModelState) -> Void) -> UUID { let id = UUID(); observers[id] = f; return id }
    public func stopObserving(_ id: UUID) { observers[id] = nil }
    private func set(_ id: String, _ s: ModelState) { states[id] = s; for o in observers.values { o(id, s) } }

    public func directory(for id: String) -> URL { root.appendingPathComponent(id.replacingOccurrences(of: "/", with: "--"), isDirectory: true) }
    private func manifestURL(_ id: String) -> URL { directory(for: id).appendingPathComponent("manifest.json") }

    public func state(of id: String) -> ModelState {
        if let s = states[id] { return s }
        let s = diskState(id); states[id] = s; return s
    }

    /// Reconstructs state from disk: installed, partially downloaded (=> paused), or absent.
    private func diskState(_ id: String) -> ModelState {
        guard let data = try? Data(contentsOf: manifestURL(id)), let plan = try? JSONDecoder().decode(DownloadPlan.self, from: data) else { return .notInstalled }
        let dir = directory(for: id)
        var done: Int64 = 0, complete = true
        for f in plan.files {
            if let a = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(f.path).path), (a[.size] as? Int64 ?? Int64(a[.size] as? Int ?? -1)) == f.size { done += f.size }
            else {
                complete = false
                if let a = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(f.path + ".part").path) { done += Int64(a[.size] as? Int ?? 0) }
            }
        }
        return complete ? .installed(bytes: plan.totalBytes) : .paused(received: done, total: plan.totalBytes)
    }

    public func installedModelIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { n in
            let id = n.replacingOccurrences(of: "--", with: "/")
            if case .installed = state(of: id) { return id } else { return nil }
        }
    }

    // MARK: planning (Hub API)
    public func makePlan(for id: String) async throws -> DownloadPlan {
        guard id.split(separator: "/").count == 2, !id.contains("..") else { throw ModelStoreError.invalidID }
        let url = URL(string: "https://huggingface.co/api/models/\(id)/tree/main?recursive=1")!
        ledger.record(host: url.host ?? "?", purpose: "model file list")
        let data = try await transport.getJSON(url, headers: [:])
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw ModelStoreError.emptyPlan }
        var files: [RemoteFile] = []
        for item in arr where (item["type"] as? String) == "file" {
            guard let path = item["path"] as? String, !path.contains(".."), !path.hasPrefix("/") else { continue }
            let ext = (path as NSString).pathExtension.lowercased()
            let name = (path as NSString).lastPathComponent
            guard Self.weightPatterns.contains(ext) || name == "tokenizer.model" else { continue }
            if path.contains("/") { continue }                                                  // MLX repos are flat; skip alternative-format subfolders
            if name.hasPrefix(".") || name == "README.md" { continue }
            let size = (item["size"] as? Int64) ?? Int64(item["size"] as? Int ?? 0)
            let lfs = (item["lfs"] as? [String: Any])?["oid"] as? String
            files.append(RemoteFile(path: path, size: size, sha256: lfs))
        }
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }) else { throw ModelStoreError.emptyPlan }
        return DownloadPlan(modelID: id, revision: "main", files: files.sorted { $0.size < $1.size })
    }

    // MARK: lifecycle
    public func start(_ id: String) {
        if let t = tasks[id], !t.isCancelled, case .downloading = state(of: id) { return }
        set(id, .planning)
        tasks[id] = Task { [weak self] in await self?.run(id) }
    }

    public func pause(_ id: String) {
        tasks[id]?.cancel(); tasks[id] = nil
        let s = diskState(id)
        if case .installed = s { set(id, s) } else if case .notInstalled = s { set(id, .notInstalled) } else { set(id, s) }
    }

    public func remove(_ id: String) {
        tasks[id]?.cancel(); tasks[id] = nil
        try? FileManager.default.removeItem(at: directory(for: id))
        set(id, .notInstalled)
    }

    public func totalInstalledBytes() -> Int64 {
        installedModelIDs().reduce(0) { acc, id in
            if case .installed(let b) = state(of: id) { return acc + b } else { return acc }
        }
    }

    private func run(_ id: String) async {
        do {
            let dir = directory(for: id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var plan: DownloadPlan
            if let data = try? Data(contentsOf: manifestURL(id)), let p = try? JSONDecoder().decode(DownloadPlan.self, from: data) { plan = p }
            else {
                plan = try await makePlan(for: id)
                try JSONEncoder().encode(plan).write(to: manifestURL(id), options: .atomic)
            }
            let pending = plan.files.filter { Self.onDiskSize(dir.appendingPathComponent($0.path)) != $0.size }
            let need = pending.reduce(Int64(0)) { $0 + $1.size } - (plan.files.reduce(Int64(0)) { $0 + Self.onDiskSize(dir.appendingPathComponent($1.path + ".part")) })
            let avail = freeSpace()
            if need > avail - 200_000_000 { throw ModelStoreError.notEnoughSpace(needed: need, available: avail) }

            var received = plan.files.reduce(Int64(0)) { acc, f in
                let final = Self.onDiskSize(dir.appendingPathComponent(f.path))
                return acc + (final == f.size ? final : Self.onDiskSize(dir.appendingPathComponent(f.path + ".part")))
            }
            let total = plan.totalBytes
            for f in plan.files {
                try Task.checkCancellation()
                let final = dir.appendingPathComponent(f.path)
                if Self.onDiskSize(final) == f.size { continue }
                try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
                let part = dir.appendingPathComponent(f.path + ".part")
                let url = URL(string: "https://huggingface.co/\(id)/resolve/\(plan.revision)/\(f.path)")!
                guard NetworkPolicy.isAllowedModelHost(url.host ?? "") else { throw ModelStoreError.hostNotAllowed(url.host ?? "?") }
                let base = received - Self.onDiskSize(part)
                ledger.record(host: url.host ?? "?", purpose: "model download: \(f.path)")
                set(id, .downloading(received: received, total: total, file: f.path))
                let box = ProgressBox()
                let sizeNow = try await transport.download(url, to: part, resumeFrom: Self.onDiskSize(part), headers: [:]) { [weak self] written in
                    guard box.shouldPublish() else { return }
                    Task { await self?.set(id, .downloading(received: base + written, total: total, file: f.path)) }
                }
                guard sizeNow == f.size else { try? FileManager.default.removeItem(at: part); throw ModelStoreError.sizeMismatch(f.path) }
                if let want = f.sha256 {
                    set(id, .verifying(file: f.path))
                    let got = try await Task.detached { try SHA256Hasher.hex(ofFile: part) }.value
                    guard got == want else { try? FileManager.default.removeItem(at: part); throw ModelStoreError.checksumMismatch(f.path) }
                }
                try? FileManager.default.removeItem(at: final)
                try FileManager.default.moveItem(at: part, to: final)
                ledger.record(host: url.host ?? "?", purpose: "downloaded \(f.path)", bytes: f.size)
                received = base + f.size
            }
            set(id, .installed(bytes: total))
        } catch is CancellationError {
            set(id, diskState(id))
        } catch {
            if Task.isCancelled { set(id, diskState(id)) } else { set(id, .failed(error.localizedDescription)) }
        }
        tasks[id] = nil
    }

    static func onDiskSize(_ url: URL) -> Int64 {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return Int64(a[.size] as? Int ?? 0)
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock(); private var last = Date.distantPast
    func shouldPublish() -> Bool { lock.withLock { let n = Date(); if n.timeIntervalSince(last) > 0.25 { last = n; return true }; return false } }
}
