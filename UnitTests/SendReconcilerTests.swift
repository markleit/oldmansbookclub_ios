import XCTest
@testable import OldMansBookClub

/// The live-path half of "an optimistic bubble meets its server echo", plus a cross-check that it
/// agrees with the load-path half (`ChatCache.merge`).
///
/// Those two have always been independent implementations of the same idea — one for a message
/// arriving over SignalR or a REST response, one for a message arriving in a page fetch — and
/// nothing has ever verified they reach the same answer. The final test here does.
final class SendReconcilerTests: XCTestCase {

    private func outcome(for message: Message, in messages: [Message], myUserId: UUID? = Fixture.me) -> SendReconciler.Outcome {
        SendReconciler.outcome(for: message, in: messages, myUserId: myUserId, bookClubId: Fixture.clubId)
    }

    func testAMessageForAnotherClubIsIgnored() {
        var stray = Fixture.message()
        stray.clubId = UUID()

        // Chats for several clubs can be alive at once; applying another club's message here
        // would drop it into the wrong conversation.
        XCTAssertEqual(outcome(for: stray, in: []), .ignoreWrongClub)
    }

    func testAMessageAlreadyOnScreenIsIgnored() {
        let message = Fixture.message()

        // Both transports can deliver the same confirmation — the REST response and the SignalR
        // echo. Whichever arrives second must do nothing at all.
        XCTAssertEqual(outcome(for: message, in: [message]), .ignoreAlreadyApplied)
    }

    func testTheAlreadyAppliedCheckWinsOverTheOptimisticMatch() {
        let clientId = UUID()
        let confirmed = Fixture.confirmed(of: clientId)

        // Both an optimistic bubble AND the confirmed message are present — the echo raced the
        // REST response and lost. Replacing again would be harmless; inserting would not.
        let result = outcome(for: confirmed, in: [confirmed, Fixture.optimistic(clientId: clientId)])

        XCTAssertEqual(result, .ignoreAlreadyApplied)
    }

    func testOurOwnConfirmedSendReplacesItsOptimisticBubbleInPlace() {
        let clientId = UUID()
        let optimistic = Fixture.optimistic(clientId: clientId)
        let confirmed = Fixture.confirmed(of: clientId)

        let result = outcome(for: confirmed, in: [Fixture.message(), optimistic])

        // In place, at the bubble's existing index — not removed and re-inserted, which would
        // make the user's own message jump position as it confirms.
        XCTAssertEqual(result, .replaceOptimistic(index: 1, clientId: clientId, previousMediaUrl: nil))
    }

    func testReplacingAMediaBubbleReportsItsLocalFileForCleanup() {
        let clientId = UUID()
        var optimistic = Fixture.optimistic(clientId: clientId)
        optimistic.type = .voice
        optimistic.mediaUrl = "file:///tmp/pending-voice.m4a"
        var confirmed = Fixture.confirmed(of: clientId)
        confirmed.type = .voice

        let result = outcome(for: confirmed, in: [optimistic])

        // The caller deletes this file. Losing the URL here means the recording stays on disk
        // forever — invisible, and never cleaned up by anything else.
        XCTAssertEqual(result, .replaceOptimistic(index: 0, clientId: clientId,
                                                  previousMediaUrl: "file:///tmp/pending-voice.m4a"))
    }

    func testTwoIdenticalConsecutiveSendsMatchTheirOwnBubbles() {
        // #35 in one test. The bodies are identical, so anything matching on content would pair
        // the wrong bubble with the wrong confirmation — and the user would see one message
        // confirm twice while the other stayed stuck sending.
        let firstId = UUID(), secondId = UUID()
        let messages = [Fixture.optimistic(clientId: secondId, body: "ok", secondsAfterEpoch: 1),
                        Fixture.optimistic(clientId: firstId, body: "ok", secondsAfterEpoch: 0)]

        let first = outcome(for: Fixture.confirmed(of: firstId, body: "ok"), in: messages)
        let second = outcome(for: Fixture.confirmed(of: secondId, body: "ok"), in: messages)

        XCTAssertEqual(first, .replaceOptimistic(index: 1, clientId: firstId, previousMediaUrl: nil))
        XCTAssertEqual(second, .replaceOptimistic(index: 0, clientId: secondId, previousMediaUrl: nil))
    }

    func testSomeoneElsesMessageIsInserted() {
        XCTAssertEqual(outcome(for: Fixture.message(senderId: Fixture.other), in: []), .insert)
    }

    func testOurOwnMessageFromAnotherDeviceIsInserted() {
        let clientId = UUID()

        // Same account, but this device has no optimistic bubble for it — it was sent from the
        // iPad. It is a new arrival here, not a reconciliation.
        XCTAssertEqual(outcome(for: Fixture.confirmed(of: clientId), in: []), .insert)
    }

    func testAConfirmationCarryingNoClientIdIsInserted() {
        var confirmed = Fixture.message(senderId: Fixture.me)
        confirmed.clientId = nil

        // Forwards carry no clientId, and neither does an older client's send. With nothing to
        // match on, inserting is the only safe answer.
        XCTAssertEqual(outcome(for: confirmed, in: []), .insert)
    }

    func testSignedOutTheOptimisticMatchIsSkipped() {
        let clientId = UUID()

        let result = outcome(for: Fixture.confirmed(of: clientId),
                             in: [Fixture.optimistic(clientId: clientId)],
                             myUserId: nil)

        XCTAssertEqual(result, .insert)
    }

    // ---- agreement with the load path ---------------------------------------------------------

    func testTheLivePathAndTheLoadPathAgreeOnEveryCase() {
        // ChatCache.merge (load) and SendReconciler (live) are separate implementations of the
        // same rule. A user cannot tell which one ran — the message either duplicates or it does
        // not — so any disagreement between them is a bug in whichever one is wrong. Nothing has
        // checked this before.
        let clientId = UUID()
        let cases: [(name: String, existing: [Message], incoming: Message)] = [
            ("own confirmed send with its bubble present",
             [Fixture.optimistic(clientId: clientId)], Fixture.confirmed(of: clientId)),
            ("own confirmed send with no bubble",
             [], Fixture.confirmed(of: clientId)),
            ("someone else's message",
             [], Fixture.message(senderId: Fixture.other)),
            ("a message already on screen",
             [Fixture.message(id: clientId)], Fixture.message(id: clientId)),
        ]

        for (name, existing, incoming) in cases {
            let (merged, _) = ChatCache.merge(existing: existing, incoming: [incoming], myUserId: Fixture.me)

            let live = outcome(for: incoming, in: existing)
            let liveCount: Int
            switch live {
            case .ignoreWrongClub, .ignoreAlreadyApplied: liveCount = existing.count
            case .replaceOptimistic: liveCount = existing.count
            case .insert: liveCount = existing.count + 1
            }

            XCTAssertEqual(merged.count, liveCount,
                           "load and live paths disagree on how many messages remain for: \(name)")
            XCTAssertTrue(merged.contains { $0.id == incoming.id },
                          "the confirmed message went missing on the load path for: \(name)")
        }
    }
}
