import XCTest
@testable import OldMansBookClub

/// The trail is only useful if it can be found again by pid on a LATER launch and stays bounded —
/// a report that attaches the wrong process's trail would point the investigation at the wrong
/// screen, which is worse than no trail at all.
final class BreadcrumbsTests: XCTestCase {
    private let key = "diagnosticBreadcrumbs"
    private var saved: Any?

    override func setUp() {
        saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.set(saved, forKey: key)
    }

    private var myPid: Int32 { ProcessInfo.processInfo.processIdentifier }

    func testEventsAreRetrievableByThisProcessesPid() throws {
        Breadcrumbs.record("tab Admin")
        Breadcrumbs.record("background")
        let trail = try XCTUnwrap(Breadcrumbs.trail(forPid: myPid))
        XCTAssertTrue(trail.contains("tab Admin"))
        XCTAssertTrue(trail.hasSuffix("background"), "events must be oldest-first: \(trail)")
    }

    func testAnotherProcessesTrailIsNotReturned() {
        Breadcrumbs.record("tab Admin")
        XCTAssertNil(Breadcrumbs.trail(forPid: myPid &+ 1))
    }

    func testTrailKeepsOnlyTheMostRecentEvents() throws {
        for i in 0..<40 { Breadcrumbs.record("e\(i)") }
        let trail = try XCTUnwrap(Breadcrumbs.trail(forPid: myPid))
        XCTAssertTrue(trail.hasSuffix("e39"))
        XCTAssertFalse(trail.contains("e20 "), "old events should have been dropped: \(trail)")
        XCTAssertLessThanOrEqual(trail.components(separatedBy: " → ").count, 15)
    }

    func testOldestProcessesAreEvicted() throws {
        // Ten older processes (launch epochs 1…10), then this one records — the oldest must go.
        var seeded: [String: [String]] = [:]
        for p in 1...10 { seeded[String(p)] = [String(p), "+0s launch"] }
        UserDefaults.standard.set(seeded, forKey: key)

        Breadcrumbs.record("tab Profile")

        XCTAssertNil(Breadcrumbs.trail(forPid: 1), "the oldest process should have been evicted")
        XCTAssertNotNil(Breadcrumbs.trail(forPid: 10))
        XCTAssertNotNil(Breadcrumbs.trail(forPid: myPid))
    }
}
