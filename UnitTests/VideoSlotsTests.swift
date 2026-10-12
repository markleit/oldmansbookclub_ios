import XCTest
@testable import OldMansBookClub

/// #204 design v2 — the upload slots kept on the phone (docs/SEND_REQUIREMENTS.md VA rows).
final class VideoSlotsTests: XCTestCase {
    private var dir: URL!
    private let club = UUID(), now = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("VideoSlotsTests-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func slot(ageHours: Double, lifeDays: Double = 7) -> VideoSlot {
        let fetched = now.addingTimeInterval(-ageHours * 3600)
        return VideoSlot(uploadUrl: "https://b/\(UUID()).mp4?sig", mediaUrl: "https://b/\(UUID()).mp4",
                         fetchedAt: fetched, expiresAt: fetched.addingTimeInterval(lifeDays * 86400))
    }

    func testAVideoTakesTheNewestUnexpiredSlotAndUsesItUp() {
        var store = VideoSlots(directory: dir)
        let old = slot(ageHours: 30), newest = slot(ageHours: 1), expired = slot(ageHours: 200)
        store.add([old, newest, expired], clubId: club, now: now.addingTimeInterval(-40 * 3600))   // all "fresh" then

        XCTAssertEqual(store.take(clubId: club, now: now), newest)
        XCTAssertEqual(store.take(clubId: club, now: now), old)
        XCTAssertNil(store.take(clubId: club, now: now), "the expired one is never handed out")
        XCTAssertNil(store.take(clubId: UUID(), now: now), "another club's are its own")
    }

    func testThreePerClubCountingOnlyFreshOnes() {
        var store = VideoSlots(directory: dir)
        XCTAssertEqual(store.toFetch(clubId: club, now: now), 3)
        store.add([slot(ageHours: 2), slot(ageHours: 30)], clubId: club, now: now.addingTimeInterval(-31 * 3600))
        XCTAssertEqual(store.toFetch(clubId: club, now: now), 2, "a day-old slot is due for swapping")
    }

    func testOldSlotsGoWhenFreshOnesArriveNotBefore() {
        var store = VideoSlots(directory: dir)
        let old = slot(ageHours: 30)
        store.add([old], clubId: club, now: now.addingTimeInterval(-31 * 3600))
        XCTAssertEqual(store.all()[club], [old], "kept until replaced")

        let fresh = [slot(ageHours: 0), slot(ageHours: 0)]
        store.add(fresh, clubId: club, now: now)
        XCTAssertEqual(store.all()[club], fresh)
    }

    func testSigningOutDiscardsThem() {
        var store = VideoSlots(directory: dir)
        store.add([slot(ageHours: 0)], clubId: club, now: now)
        VideoSlots.removeAll(in: dir)
        XCTAssertTrue(VideoSlots(directory: dir).all().isEmpty)
    }
}
