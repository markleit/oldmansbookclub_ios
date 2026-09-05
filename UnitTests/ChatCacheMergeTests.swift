import XCTest
@testable import OldMansBookClub

/// `ChatCache.merge` is the load-path half of "an optimistic bubble meets its server echo".
///
/// It is a pure static function with its one dependency (`myUserId`) already injected, so it needs
/// no seam at all — and it decides whether a user sees one message or two after every send. The
/// duplicate-bubble bug series (#35, #131, #146) all lived on this boundary.
final class ChatCacheMergeTests: XCTestCase {

    func testIncomingMessagesAreAddedNewestFirst() {
        let old = Fixture.message(body: "old", secondsAfterEpoch: 0)
        let new = Fixture.message(body: "new", secondsAfterEpoch: 60)

        let (messages, _) = ChatCache.merge(existing: [old], incoming: [new], myUserId: Fixture.me)

        XCTAssertEqual(messages.map(\.body), ["new", "old"])
    }

    func testAFreshFetchWinsOnAnOverlappingId() {
        let id = UUID()
        let stale = Fixture.message(id: id, body: "before the edit")
        let edited = Fixture.message(id: id, body: "after the edit")

        let (messages, _) = ChatCache.merge(existing: [stale], incoming: [edited], myUserId: Fixture.me)

        // Server-side edits and deletions have to propagate, so the incoming copy replaces the
        // cached one rather than being discarded as a duplicate.
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.body, "after the edit")
    }

    func testAConfirmedSendReplacesItsOptimisticBubbleRatherThanDoublingIt() {
        let clientId = UUID()
        let optimistic = Fixture.optimistic(clientId: clientId)
        let confirmed = Fixture.confirmed(of: clientId)

        let (messages, reconciled) = ChatCache.merge(
            existing: [optimistic], incoming: [confirmed], myUserId: Fixture.me)

        // One bubble, and it is the server's. This is the exact regression a user sees as their
        // own message appearing twice after the app was backgrounded mid-send.
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.id, confirmed.id)
        XCTAssertEqual(reconciled, [clientId])
    }

    func testReconciliationReportsEveryClientIdSoPendingStateCanBeCleared() {
        let first = UUID(), second = UUID()

        let (_, reconciled) = ChatCache.merge(
            existing: [Fixture.optimistic(clientId: first), Fixture.optimistic(clientId: second)],
            incoming: [Fixture.confirmed(of: first), Fixture.confirmed(of: second)],
            myUserId: Fixture.me)

        // The caller clears the send queue and watchdog from this list. A missing id leaves a
        // message stuck as "sending" forever even though it arrived.
        XCTAssertEqual(Set(reconciled), [first, second])
    }

    func testSomeoneElsesMessageIsNeverReconciledAgainstYourBubble() {
        let clientId = UUID()
        let mine = Fixture.optimistic(clientId: clientId)
        // Same clientId, different sender — a clientId is only unique per user, so without the
        // sender check another member's message could delete your unsent bubble.
        let theirs = Fixture.message(id: UUID(), senderId: Fixture.other, clientId: clientId)

        let (messages, reconciled) = ChatCache.merge(
            existing: [mine], incoming: [theirs], myUserId: Fixture.me)

        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(reconciled.isEmpty)
    }

    func testPassingNoUserIdSkipsReconciliationEntirely() {
        let clientId = UUID()

        let (messages, reconciled) = ChatCache.merge(
            existing: [Fixture.optimistic(clientId: clientId)],
            incoming: [Fixture.confirmed(of: clientId)],
            myUserId: nil)

        // Signed out, or a prefetch with no identity: better to keep both than to guess which
        // account an optimistic bubble belonged to.
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(reconciled.isEmpty)
    }

    func testAConfirmedSendWithNoOptimisticBubbleIsSimplyInserted() {
        let clientId = UUID()

        let (messages, reconciled) = ChatCache.merge(
            existing: [], incoming: [Fixture.confirmed(of: clientId)], myUserId: Fixture.me)

        // The common case on a second device, and after a cache clear: nothing to reconcile, but
        // the id is still reported so any pending state elsewhere is cleared.
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(reconciled, [clientId])
    }

    func testDuplicateIncomingMessagesCollapseToOne() {
        let id = UUID()
        let message = Fixture.message(id: id)

        let (messages, _) = ChatCache.merge(existing: [], incoming: [message, message], myUserId: Fixture.me)

        XCTAssertEqual(messages.count, 1)
    }

    func testMergingNothingLeavesTheCacheUntouched() {
        let existing = [Fixture.message(body: "a", secondsAfterEpoch: 10),
                        Fixture.message(body: "b", secondsAfterEpoch: 0)]

        let (messages, reconciled) = ChatCache.merge(existing: existing, incoming: [], myUserId: Fixture.me)

        XCTAssertEqual(messages.map(\.body), ["a", "b"])
        XCTAssertTrue(reconciled.isEmpty)
    }
}
