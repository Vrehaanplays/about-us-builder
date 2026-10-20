import Foundation
import XCTest
@testable import PersonalAICore

func makeTempDB(profile: ArchiveDatabase.Profile = .phone) throws -> (ArchiveDatabase, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pai-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let db = try ArchiveDatabase(path: dir.appendingPathComponent("archive.sqlite").path, profile: profile)
    return (db, dir)
}

func ts(_ s: String) -> Double {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d.timeIntervalSince1970 }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)!.timeIntervalSince1970
}
