import XCTest
@testable import OldMansBookClub

/// #203 — the in-app send log is what Feedback reports carry, so it must keep the newest events,
/// stay bounded, and never include anything beyond the short id and the detail it was given.
final class SendLogTests: XCTestCase {
    func testKeepsTheNewestEventsAndStaysBounded() {
        let marker = UUID().uuidString.prefix(6)
        for i in 0..<620 { SendLog.note("unit-test \(marker)", nil, "n=\(i)") }
        let lines = SendLog.recent(limit: 1_000).split(separator: "\n")
        XCTAssertLessThanOrEqual(lines.count, 500, "the rolling log must stay bounded")
        XCTAssertTrue(lines.last?.hasSuffix("n=619") == true, "newest event should be last, got \(lines.last ?? "")")
        XCTAssertFalse(lines.contains { $0.hasSuffix("unit-test \(marker) [-] n=0") }, "oldest events should roll off")
    }

    func testRecentHonoursItsLimitAndShortensIds() {
        let id = UUID()
        SendLog.note("unit-test id", id, "detail")
        let recent = SendLog.recent(limit: 1)
        XCTAssertEqual(recent.split(separator: "\n").count, 1)
        XCTAssertTrue(recent.contains("[\(id.uuidString.prefix(8))]"), "ids are logged as 8-char prefixes")
        XCTAssertFalse(recent.contains(id.uuidString), "the full id must not appear")
    }
}
