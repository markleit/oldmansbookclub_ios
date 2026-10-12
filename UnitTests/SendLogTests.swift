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

    func test252TheLogIsSavedEvenWhenItsFolderDoesntExistYet() throws {
        // A fresh install has no Application Support folder until something creates it; the log
        // used to fail to save there, silently, so Feedback reports carried nothing.
        let folder = SendLog.fileURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))

        let marker = "unit-test fresh-install \(UUID().uuidString.prefix(6))"
        SendLog.note(marker)
        _ = SendLog.recent(limit: 1)   // waits for the write, which runs on the log's queue

        let saved = try String(contentsOf: SendLog.fileURL, encoding: .utf8)
        XCTAssertTrue(saved.contains(marker), "the line must be on disk, not only in memory")
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
