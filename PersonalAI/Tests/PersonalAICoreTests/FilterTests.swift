import XCTest
@testable import PersonalAICore

final class FilterTests: XCTestCase {
    func run(_ chunks: [String]) -> String { var s = ThinkStripper(); var out = chunks.map { s.push($0) }.joined(); out += s.finish(); return out }

    func testRemovesThinkingEvenWhenTagsAreSplit() {
        XCTAssertEqual(run(["Hello <thi", "nk>secret ", "reasoning</th", "ink>\n\nAnswer."]), "Hello Answer.")
        XCTAssertEqual(run(["<think>x</think>Hi"]), "Hi")
        XCTAssertEqual(run(["plain text only"]), "plain text only")
        XCTAssertEqual(run(["a < b and c > d"]), "a < b and c > d", "angle brackets that are not tags survive")
        XCTAssertEqual(run(["<think>never closed"]), "", "unfinished reasoning is never shown")
    }

    func testKVTierIsStickyAndShrinksUnderPressure() {
        XCTAssertEqual(KVTier.choose(requested: 9000, current: nil), 8192)
        XCTAssertEqual(KVTier.choose(requested: 10_000, current: 8192), 8192, "small growth does not rebuild the cache")
        XCTAssertEqual(KVTier.choose(requested: 17_000, current: 8192), 16_384, "doubling is worth a rebuild")
        XCTAssertEqual(KVTier.choose(requested: 5000, current: 8192), 4096, "memory pressure shrinks immediately")
        XCTAssertEqual(KVTier.choose(requested: 100, current: nil), 2048)
    }
}
