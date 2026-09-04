import XCTest
@testable import OldMansBookClub

/// `HeardStore.seed` is set algebra with three inputs and two collections, and it has the worst
/// bug history in the app (#102, #107, #108, #119 — a badge that could not be cleared). It runs on
/// every chat load for every user, and until now nothing verified it.
@MainActor
final class HeardStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // A scratch suite per test: real UserDefaults semantics, none of the shared state.
        suiteName = "HeardStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore(account: String = "account-a") -> HeardStore {
        HeardStore(defaults: defaults, currentUserId: { account })
    }

    // ---- the union -------------------------------------------------------------------------

    func testAMarkIsHeardImmediatelyEvenBeforeTheServerAcknowledgesIt() {
        let store = makeStore()
        let id = UUID()

        store.markHeard([id], bookId: Fixture.bookId)

        // heard = confirmed ∪ pending. Without the pending half, tapping play would leave the
        // bubble grey until a round trip completed — or forever, offline.
        XCTAssertTrue(store.isHeard(id))
        XCTAssertEqual(store.pending[id], Fixture.bookId)
        XCTAssertFalse(store.confirmed.contains(id))
    }

    func testConfirmingMovesAMarkFromTheOutboxIntoTheCache() {
        let store = makeStore()
        let id = UUID()
        store.markHeard([id], bookId: Fixture.bookId)

        store.confirm([id])

        XCTAssertTrue(store.confirmed.contains(id))
        XCTAssertNil(store.pending[id])
        XCTAssertTrue(store.isHeard(id))
    }

    func testAbandoningDropsAMarkTheServerWillNeverAccept() {
        let store = makeStore()
        let id = UUID()
        store.markHeard([id], bookId: Fixture.bookId)

        store.abandon([id])

        // The server said it will never accept this id, so retrying forever is pointless — and
        // it must not be promoted to confirmed either, because it was never actually accepted.
        XCTAssertNil(store.pending[id])
        XCTAssertFalse(store.confirmed.contains(id))
        XCTAssertFalse(store.isHeard(id))
    }

    // ---- seed ------------------------------------------------------------------------------

    func testSeedAdoptsWhatTheServerKnowsAndStopsResendingIt() {
        let store = makeStore()
        let id = UUID()
        store.markHeard([id], bookId: Fixture.bookId)

        let toPush = store.seed(serverHeardIds: [id], voiceIds: [id], legacyHeardIds: [], bookId: Fixture.bookId)

        XCTAssertTrue(store.confirmed.contains(id))
        XCTAssertNil(store.pending[id])
        XCTAssertTrue(toPush.isEmpty, "the server already has this mark — re-sending it is pure noise")
    }

    func testSeedDropsACacheEntryTheServerNoLongerLists() {
        let store = makeStore()
        let stale = UUID()
        store.markHeard([stale], bookId: Fixture.bookId)
        store.confirm([stale])

        _ = store.seed(serverHeardIds: [], voiceIds: [stale], legacyHeardIds: [], bookId: Fixture.bookId)

        // The server's answer wins outright within the ids we asked about. This is the property
        // that lets a wrong local entry go away again — the old sticky flag could not, which is
        // how a device's heard state diverged permanently.
        XCTAssertFalse(store.confirmed.contains(stale))
        XCTAssertFalse(store.isHeard(stale))
    }

    func testSeedLeavesAnUnacknowledgedMarkInTheOutboxAndReportsItForPushing() {
        let store = makeStore()
        let mine = UUID()
        store.markHeard([mine], bookId: Fixture.bookId)

        let toPush = store.seed(serverHeardIds: [], voiceIds: [mine], legacyHeardIds: [], bookId: Fixture.bookId)

        // The server not listing it means it has not been TOLD, not that the mark is wrong.
        XCTAssertEqual(store.pending[mine], Fixture.bookId)
        XCTAssertEqual(toPush, [mine])
    }

    func testSeedAdoptsPreOutboxLegacyMarksIntoTheOutbox() {
        let store = makeStore()
        let legacy = UUID()

        let toPush = store.seed(serverHeardIds: [], voiceIds: [legacy], legacyHeardIds: [legacy], bookId: Fixture.bookId)

        // A pre-#119 build wrote heard state straight to sticky local storage with no outbox, so
        // a dropped receipt left nothing to retry. This is the one-time repair path for users
        // already diverged — dropping these instead would silently mark them all unheard again.
        XCTAssertEqual(store.pending[legacy], Fixture.bookId)
        XCTAssertEqual(toPush, [legacy])
    }

    func testSeedIgnoresVoiceMessagesInOtherBooks() {
        let store = makeStore()
        let elsewhere = UUID()
        store.markHeard([elsewhere], bookId: UUID())

        let toPush = store.seed(serverHeardIds: [], voiceIds: [], legacyHeardIds: [], bookId: Fixture.bookId)

        XCTAssertTrue(toPush.isEmpty)
        XCTAssertNotNil(store.pending[elsewhere], "another book's outbox must survive this book's seed")
    }

    func testSeedIsIdempotent() {
        let store = makeStore()
        let confirmedId = UUID(), pendingId = UUID()
        store.markHeard([pendingId], bookId: Fixture.bookId)

        let first = store.seed(serverHeardIds: [confirmedId], voiceIds: [confirmedId, pendingId],
                               legacyHeardIds: [], bookId: Fixture.bookId)
        let second = store.seed(serverHeardIds: [confirmedId], voiceIds: [confirmedId, pendingId],
                                legacyHeardIds: [], bookId: Fixture.bookId)

        // Every chat load calls this. If it were not idempotent the state would drift a little
        // with each open, which is exactly the shape of a bug nobody can reproduce on demand.
        XCTAssertEqual(first, second)
        XCTAssertEqual(store.confirmed, [confirmedId])
        XCTAssertEqual(store.pending, [pendingId: Fixture.bookId])
    }

    // ---- persistence and account scoping -----------------------------------------------------

    func testStateSurvivesARelaunch() {
        let confirmedId = UUID(), pendingId = UUID()
        let first = makeStore()
        first.markHeard([confirmedId], bookId: Fixture.bookId)
        first.confirm([confirmedId])
        first.markHeard([pendingId], bookId: Fixture.bookId)

        let relaunched = makeStore()

        XCTAssertTrue(relaunched.confirmed.contains(confirmedId))
        XCTAssertEqual(relaunched.pending[pendingId], Fixture.bookId)
    }

    func testSigningInAsSomeoneElseDropsTheStateRatherThanInheritingIt() {
        let id = UUID()
        let mine = makeStore(account: "account-a")
        mine.markHeard([id], bookId: Fixture.bookId)
        mine.confirm([id])

        let theirs = makeStore(account: "account-b")

        // An outbox is worse than a cache here: inherited marks would be replayed under the new
        // account's token, marking messages heard that this person never played.
        XCTAssertFalse(theirs.isHeard(id))
        XCTAssertTrue(theirs.confirmed.isEmpty)
        XCTAssertTrue(theirs.pending.isEmpty)
    }
}
