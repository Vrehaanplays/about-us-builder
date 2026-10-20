import Foundation
import PersonalAICore

/// Streams model files to disk with HTTP Range resume. Only hosts allowed by `NetworkPolicy` are ever contacted, including redirect targets.
final class URLSessionTransport: NSObject, HTTPTransport, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private struct Job {
        var handle: FileHandle
        var offset: Int64
        var received: Int64 = 0
        var restarted = false
        var progress: @Sendable (Int64) -> Void
        var continuation: CheckedContinuation<Int64, Error>
        var failure: Error?
    }
    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.waitsForConnectivity = true
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    func getJSON(_ url: URL, headers: [String: String]) async throws -> Data {
        guard NetworkPolicy.isAllowedModelHost(url.host ?? "") else { throw ModelStoreError.hostNotAllowed(url.host ?? "?") }
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("PersonalAI-iOS", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "HTTP", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "The model server answered \(http.statusCode)."])
        }
        return data
    }

    func download(_ url: URL, to file: URL, resumeFrom offset: Int64, headers: [String: String], progress: @Sendable @escaping (Int64) -> Void) async throws -> Int64 {
        guard NetworkPolicy.isAllowedModelHost(url.host ?? "") else { throw ModelStoreError.hostNotAllowed(url.host ?? "?") }
        if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        var req = URLRequest(url: url)
        req.setValue("PersonalAI-iOS", forHTTPHeaderField: "User-Agent")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: req)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int64, Error>) in
                lock.withLock { jobs[task.taskIdentifier] = Job(handle: handle, offset: offset, progress: progress, continuation: cont) }
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    // MARK: delegate
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.allow); return }
        lock.lock(); defer { lock.unlock() }
        guard var job = jobs[dataTask.taskIdentifier] else { completionHandler(.cancel); return }
        switch http.statusCode {
        case 206: break
        case 200:
            if job.offset > 0 {       // server ignored Range: start over rather than corrupt the file
                try? job.handle.truncate(atOffset: 0); try? job.handle.seek(toOffset: 0)
                job.offset = 0; job.restarted = true
            }
        case 416:                     // asked for bytes beyond the end: file is already complete
            job.failure = nil
            jobs[dataTask.taskIdentifier] = job
            completionHandler(.cancel); return
        default:
            job.failure = NSError(domain: "HTTP", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "The model server answered \(http.statusCode)."])
            jobs[dataTask.taskIdentifier] = job
            completionHandler(.cancel); return
        }
        jobs[dataTask.taskIdentifier] = job
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var job = jobs[dataTask.taskIdentifier] else { lock.unlock(); return }
        do { try job.handle.write(contentsOf: data) } catch { job.failure = error; jobs[dataTask.taskIdentifier] = job; lock.unlock(); dataTask.cancel(); return }
        job.received += Int64(data.count)
        jobs[dataTask.taskIdentifier] = job
        let total = job.offset + job.received
        let cb = job.progress
        lock.unlock()
        cb(total)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard NetworkPolicy.isAllowedModelHost(request.url?.host ?? "") else { completionHandler(nil); return }
        var next = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") { next.setValue(range, forHTTPHeaderField: "Range") }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard let job = jobs.removeValue(forKey: task.taskIdentifier) else { lock.unlock(); return }
        lock.unlock()
        try? job.handle.synchronize(); try? job.handle.close()
        let total = job.offset + job.received
        if let f = job.failure { job.continuation.resume(throwing: f); return }
        if let e = error as? URLError, e.code == .cancelled { job.continuation.resume(throwing: CancellationError()); return }
        if let http = task.response as? HTTPURLResponse, http.statusCode == 416 { job.continuation.resume(returning: job.offset); return }
        if let error { job.continuation.resume(throwing: error); return }
        job.continuation.resume(returning: total)
    }
}
