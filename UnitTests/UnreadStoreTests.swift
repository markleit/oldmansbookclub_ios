import XCTest
@testable import OldMansBookClub

/// The client-side cache of the server's unread numbers, and the only thing that writes the app
/// icon badge.
@MainActor
final class UnreadStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    /// Every value the store asked the OS to put on the icon, in order.
    private var badgeWrites: [Int]!

    override func setUp() {
        super.setUp()
        suiteName = "UnreadStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        badgeWrites = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore(account: String = "account-a") -> UnreadStore {
        UnreadStore(defaults: defaults, currentUserId: { account }, writeBadge: { [weak self] in self?.badgeWrites.append($0) })
    }

    private let bookA = UUID(), bookB = UUID()

    // ---- seeding ----------------------------------------------------------------------------

    func testSeedingReplacesTheCacheAndDropsBooksTheServerNoLongerReturns() {
        let store = makeStore()
        store.seed([bookA: 3, bookB: 1])

        store.seed([bookA: 2])

        // A book removed from the club must leave the sum, or the icon shows unread for a book
        // the user cannot even open.
        XCTAssertEqual(store.counts, [bookA: 2])
        XCTAssertEqual(store.total, 2)
    }

    func testSeedingPreservesTheOpenChatsCount() {
        let store = makeStore()
        store.seed([bookA: 5, bookB: 1])
        store.setActiveBook(bookA)
        store.set(bookId: bookA, count: 0)   // the user just read it

        // A library reload fires on every foreground and may well have been issued before that
        // read landed. Letting it win would bounce the count the user just cleared back up.
        store.seed([bookA: 5, bookB: 1])

        XCTAssertEqual(store.counts[bookA], 0)
        XCTAssertEqual(store.counts[bookB], 1)
    }

    func testTheBadgeIsNotWrittenBeforeTheFirstSeed() {
        let store = makeStore()

        store.set(bookId: bookA, count: 4)

        // Before a books fetch lands, the sum of what we hold is not the user's real total —
        // writing it would wipe a correct badge a push had already set.
        XCTAssertTrue(badgeWrites.isEmpty)
    }

    func testTheBadgeIsTheSumAcrossBooks() {
        let store = makeStore()

        store.seed([bookA: 3, bookB: 4])

        XCTAssertEqual(badgeWrites.last, 7)
    }

    // ---- setting and bumping ------------------------------------------------------------------

    func testCountsNeverGoNegative() {
        let store = makeStore()
        store.seed([bookA: 1])

        store.bump(bookId: bookA, by: -5)

        XCTAssertEqual(store.counts[bookA], 0)
    }

    func testWritingTheSameCountDoesNotRepaintTheBadge() {
        let store = makeStore()
        store.seed([bookA: 2])
        let writesAfterSeed = badgeWrites.count

        store.set(bookId: bookA, count: 2)

        XCTAssertEqual(badgeWrites.count, writesAfterSeed)
    }

    func testThePushPathUpdatesTheCountWithoutTouchingTheBadge() {
        let store = makeStore()
        store.seed([bookA: 1])
        let writesAfterSeed = badgeWrites.count

        store.set(bookId: bookA, count: 9, writesBadge: false)

        // The push payload already carried a server-computed TOTAL that the OS has applied.
        // Re-deriving the icon here from a sum whose other books are older would replace a fresh
        // number with a staler one (#119) — so the count moves and the icon does not.
        XCTAssertEqual(store.counts[bookA], 9)
        XCTAssertEqual(badgeWrites.count, writesAfterSeed)
    }

    // ---- persistence and account scoping -------------------------------------------------------

    func testCountsSurviveARelaunchAndRepaintTheIcon() {
        makeStore().seed([bookA: 3])
        badgeWrites = []

        let relaunched = makeStore()

        // A cold launch that never reaches the server must still show the last known truth
        // rather than a fabricated zero — and must repaint the icon to match it.
        XCTAssertEqual(relaunched.counts[bookA], 3)
        XCTAssertEqual(badgeWrites.last, 3)
    }

    func testSigningInAsSomeoneElseClearsTheCountsAndTheIcon() {
        makeStore(account: "account-a").seed([bookA: 3])
        badgeWrites = []

        let theirs = makeStore(account: "account-b")

        XCTAssertTrue(theirs.counts.isEmpty)
        XCTAssertEqual(badgeWrites.first, 0, "the previous account's number must come off the icon")
    }
}
