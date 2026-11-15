import XCTest
@testable import OldMansBookClub

/// #275 (docs/SEND_REQUIREMENTS.md O6, D2) — "↑ N unread": any unread message above the screen, unread
/// as the server counts it (the library number: voice until heard), oldest first. Written from the
/// agreed rows, not from the code: each test names the situation it proves.
final class UnreadAboveTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func ref(_ seconds: Double, id: UUID = UUID()) -> UnreadAbove.Ref {
        UnreadAbove.Ref(id: id, sentAt: t0.addingTimeInterval(seconds))
    }

    // MARK: - Opening a chat

    func testABacklogAboveTheScreenPointsAtTheOldestUnreadAndCountsWhatIsAbove() {
        // Away for a while: five unread; you land at the newest, two of them fit on screen.
        let unread = (1...5).map { ref(Double($0) * 10) }
        var state = UnreadAbove()
        state.adopt(unread)
        state.markSeen([unread[3].id, unread[4].id])   // on screen at the bottom

        let pill = state.pill(oldestOnScreen: unread[3])

        XCTAssertEqual(pill, UnreadAbove.Pill(target: unread[0].id, count: 3),
                       "reading down from the oldest covers the rest")
    }

    func testNoPillWhenEveryUnreadMessageIsOnScreen() {
        let unread = [ref(10), ref(20)]
        var state = UnreadAbove()
        state.adopt(unread)
        state.markSeen(unread.map(\.id))

        XCTAssertNil(state.pill(oldestOnScreen: ref(5)))
    }

    func testNothingUnreadMeansNoPillHoweverMuchHistoryIsAboveTheScreen() {
        // The reported false alarm: the phone's saved chat held only the reader's own message, so a
        // fetch made three-day-old messages look new. The pill no longer asks the saved chat at all —
        // the server says nothing is unread, so there's nothing to point at.
        var state = UnreadAbove()
        state.adopt([])

        XCTAssertNil(state.pill(oldestOnScreen: ref(1_000)))
    }

    func testALateArrivalAPushAlreadyDownloadedStillGetsThePill() {
        // A message tapped earlier and delivered late is already in the saved chat (the push woke the
        // app to download it) before the chat opens. It's still unread, so it still gets the pill.
        let late = ref(15)
        var state = UnreadAbove()
        state.adopt([late])

        XCTAssertEqual(state.pill(oldestOnScreen: ref(100))?.target, late.id)
    }

    func testAVoiceMessageSkippedOnAnEarlierVisitStillCounts() {
        // Voice is unread until heard (the library counts it), so the server's list still has it on
        // the next visit even though the read marker moved past it — and the pill takes you there.
        let skippedVoice = ref(5)
        var state = UnreadAbove()
        state.adopt([skippedVoice])

        XCTAssertEqual(state.pill(oldestOnScreen: ref(50)), UnreadAbove.Pill(target: skippedVoice.id, count: 1))
    }

    func testTheTargetCanBeOlderThanEverythingLoaded() {
        // Weeks-old unheard voice isn't in the first page; it's still above, and the chat pages to it.
        let old = ref(-1_000_000)
        var state = UnreadAbove()
        state.adopt([old, ref(10)])
        state.markSeen([])

        XCTAssertEqual(state.pill(oldestOnScreen: ref(5))?.target, old.id)
        XCTAssertEqual(state.pill(oldestOnScreen: ref(5))?.count, 1, "the newer one is below the screen, not above")
    }

    // MARK: - While the chat is open

    func testSeenMessagesStopCountingAndThePillMovesOnThenGoes() {
        let a = ref(10), b = ref(20)
        var state = UnreadAbove()
        state.adopt([a, b])
        let screen = ref(100)
        XCTAssertEqual(state.pill(oldestOnScreen: screen), UnreadAbove.Pill(target: a.id, count: 2))

        state.markSeen([a.id])
        XCTAssertEqual(state.pill(oldestOnScreen: screen), UnreadAbove.Pill(target: b.id, count: 1))

        state.markSeen([b.id])
        XCTAssertNil(state.pill(oldestOnScreen: screen))
    }

    func testALiveArrivalAboveTheScreenGetsThePillOneAtTheBottomDoesNot() {
        var state = UnreadAbove()
        let screenTop = ref(100)
        state.arrived(ref(200))   // the newest: at the bottom, the "↓ New message" pill's job
        XCTAssertNil(state.pill(oldestOnScreen: screenTop))

        let outOfOrder = ref(50)   // tapped earlier, landed now: above the screen
        state.arrived(outOfOrder)
        XCTAssertEqual(state.pill(oldestOnScreen: screenTop)?.target, outOfOrder.id)
    }

    func testABlockedOrDeletedMessageIsNeverTheTarget() {
        let blocked = ref(5), deleted = ref(6), real = ref(7)
        var state = UnreadAbove()
        state.adopt([blocked, deleted, real])

        let pill = state.pill(oldestOnScreen: ref(100), hidden: [blocked.id, deleted.id])

        XCTAssertEqual(pill, UnreadAbove.Pill(target: real.id, count: 1))
        XCTAssertNil(state.pill(oldestOnScreen: ref(100), hidden: [blocked.id, deleted.id, real.id]),
                     "only hidden ones left: no pill that could never clear")
    }

    func testAForegroundReloadAddsToTheUnreadSetRatherThanReplacingIt() {
        // Back in the foreground mid-visit, the server's list no longer has what this visit's open
        // marked read — but the reader hasn't seen those yet.
        let backlog = ref(10), arrivedWhileAway = ref(500)
        var state = UnreadAbove()
        state.adopt([backlog])
        state.adopt([arrivedWhileAway])

        XCTAssertEqual(state.pill(oldestOnScreen: ref(1_000)), UnreadAbove.Pill(target: backlog.id, count: 2))
    }

    func testSomethingSeenBeforeTheListArrivedIsNotCountedLater() {
        // The saved chat renders first; the list comes back a moment later.
        let onScreen = ref(10)
        var state = UnreadAbove()
        state.markSeen([onScreen.id])
        state.adopt([onScreen])

        XCTAssertNil(state.pill(oldestOnScreen: ref(5)))
    }

    func testMarkAllAsReadClearsThePill() {
        var state = UnreadAbove()
        state.adopt([ref(10), ref(20)])
        state.clear()

        XCTAssertNil(state.pill(oldestOnScreen: ref(100)))
    }

    func testEqualTapTimesUseTheChatsOwnTieBreak() {
        // Same tap time as the oldest on screen: the chat orders by id, and so does the pill.
        let screen = ref(10, id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!)
        let above = ref(10, id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!)
        let below = ref(10, id: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000000")!)
        var state = UnreadAbove()
        state.adopt([above, below])

        XCTAssertEqual(state.pill(oldestOnScreen: screen), UnreadAbove.Pill(target: above.id, count: 1))
    }
}

/// #275 — older history pages on from the edge of the newest page, not from a late arrival in it.
final class PageFloorTests: XCTestCase {
    private func messages(_ seconds: [Double]) -> [Message] {
        seconds.map { Fixture.message(secondsAfterEpoch: $0) }
    }

    func testAFullPageWithLateArrivalsAfterItPagesFromThePagesOwnOldest() {
        // Page of 3 (newest first), then a late arrival tapped long before it.
        let fetched = messages([300, 200, 100, -50_000])
        XCTAssertEqual(ChatOrder.pageFloor(of: fetched, pageSize: 3), Fixture.epoch.addingTimeInterval(100))
    }

    func testAShortPageIsTheWholeHistory() {
        XCTAssertEqual(ChatOrder.pageFloor(of: messages([300, 200]), pageSize: 3), Fixture.epoch.addingTimeInterval(200))
        XCTAssertNil(ChatOrder.pageFloor(of: [], pageSize: 3))
    }
}

/// #275 — a confirmed send doesn't create a saved chat of just itself.
final class ChatCacheAddConfirmedTests: XCTestCase {
    private let bookId = UUID()

    override func tearDown() {
        CacheService.shared.removeAll(withKeyPrefix: ChatCache.key(bookId: bookId))
        super.tearDown()
    }

    func testWithNoSavedChatNothingIsWritten() {
        XCTAssertFalse(ChatCache.addConfirmed(Fixture.message(), bookId: bookId, myUserId: Fixture.me, waitForWrite: true))
        XCTAssertTrue(ChatCache.load(bookId: bookId).isEmpty,
                      "a one-message saved chat would be what the next open starts from")
    }

    func testAnExistingSavedChatGainsTheMessage() {
        let earlier = Fixture.message(secondsAfterEpoch: 0)
        ChatCache.save([earlier], bookId: bookId, excludingPending: [], waitForWrite: true)
        let sent = Fixture.message(senderId: Fixture.me, secondsAfterEpoch: 10)

        XCTAssertTrue(ChatCache.addConfirmed(sent, bookId: bookId, myUserId: Fixture.me, waitForWrite: true))
        XCTAssertEqual(Set(ChatCache.load(bookId: bookId).map(\.id)), [earlier.id, sent.id])
    }
}
