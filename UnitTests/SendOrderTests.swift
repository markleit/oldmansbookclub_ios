import XCTest
@testable import OldMansBookClub

/// Send order == the order the user tapped Send, per chat. The server stamps a message when its
/// POST arrives, so the pump must never post an item while anything queued before it is unposted
/// — and must never let a failed item freeze the rest of the chat.
final class SendOrderTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    private func media(_ id: UUID, _ seq: Int, uploaded: Bool) -> SendOrder.Entry {
        .init(id: id, seq: seq, kind: .media(uploaded: uploaded))
    }
    private func text(_ id: UUID, _ seq: Int) -> SendOrder.Entry { .init(id: id, seq: seq, kind: .text) }

    func testATextWaitsBehindAnEarlierPhotoStillUploading() {
        // The reported case: photo, then "look at this" — the text must not overtake.
        XCTAssertEqual(SendOrder.next(entries: [text(b, 2), media(a, 1, uploaded: false)],
                                      failed: [], awaitingResult: []), .wait)
    }

    func testALaterPhotoThatFinishedFirstWaitsForTheEarlierVideo() {
        XCTAssertEqual(SendOrder.next(entries: [media(a, 1, uploaded: false), media(b, 2, uploaded: true)],
                                      failed: [], awaitingResult: []), .wait)
    }

    func testTheHeadPostsOnceItsUploadIsDone() {
        XCTAssertEqual(SendOrder.next(entries: [media(b, 2, uploaded: true), media(a, 1, uploaded: true)],
                                      failed: [], awaitingResult: []), .postMedia(a))
    }

    func testNothingPostsWhileTheHeadsPostIsInFlight() {
        XCTAssertEqual(SendOrder.next(entries: [media(a, 1, uploaded: true), text(b, 2)],
                                      failed: [], awaitingResult: [a]), .wait)
    }

    func testAFailedItemDoesNotHoldUpTheLine() {
        XCTAssertEqual(SendOrder.next(entries: [media(a, 1, uploaded: false), text(b, 2), text(c, 3)],
                                      failed: [a], awaitingResult: []), .postText(b))
    }

    func testIdleWhenOnlyFailedItemsRemain() {
        XCTAssertEqual(SendOrder.next(entries: [text(a, 1)], failed: [a], awaitingResult: []), .idle)
        XCTAssertEqual(SendOrder.next(entries: [], failed: [], awaitingResult: []), .idle)
    }

    func testItemsFromAnOlderBuildWithoutASeqGoFirst() {
        // seq nil is mapped to 0 by the caller: anything queued before this build shipped is older.
        XCTAssertEqual(SendOrder.next(entries: [text(b, 5), text(a, 0)], failed: [], awaitingResult: []),
                       .postText(a))
    }

    @MainActor
    func testSequenceIsMonotonicAndPersisted() {
        let suite = "SendOrderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SendOrder.nextSeq(defaults: defaults)
        let second = SendOrder.nextSeq(defaults: defaults)
        XCTAssertEqual(second, first + 1)
        // A "relaunch" reads the same store and keeps counting up.
        XCTAssertEqual(SendOrder.nextSeq(defaults: UserDefaults(suiteName: suite)!), second + 1)
    }
}
