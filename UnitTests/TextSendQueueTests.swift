import XCTest
@testable import OldMansBookClub

/// The durable text outbox (#146) — the only thing that persists an in-flight text send, since
/// ChatCache deliberately excludes pending sends from its disk cache.
@MainActor
final class TextSendQueueTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TextSendQueueTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func pending(clientId: UUID = UUID(), bookId: UUID = Fixture.bookId, body: String = "hello")
    -> TextSendQueue.PendingSend {
        .init(clientId: clientId, bookId: bookId, clubId: Fixture.clubId,
              body: body, parentMessageId: nil, queuedAt: Fixture.epoch)
    }

    func testAQueuedSendSurvivesAForceQuit() {
        let item = pending(body: "the one that must not be lost")
        TextSendQueue(defaults: defaults).enqueue(item)

        let relaunched = TextSendQueue(defaults: defaults)

        // The entire point of #146: a force-quit between "tap send" and "server ack" used to lose
        // the message with zero trace.
        XCTAssertEqual(relaunched.items.map(\.body), ["the one that must not be lost"])
    }

    func testRemovingBySendClearsTheEntry() {
        let queue = TextSendQueue(defaults: defaults)
        let item = pending()
        queue.enqueue(item)

        queue.remove(clientId: item.clientId)

        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertTrue(TextSendQueue(defaults: defaults).items.isEmpty, "removal must also persist")
    }

    func testItemsAreFilteredPerBook() {
        let queue = TextSendQueue(defaults: defaults)
        let mine = pending(bookId: Fixture.bookId, body: "this book")
        queue.enqueue(mine)
        queue.enqueue(pending(bookId: UUID(), body: "another book"))

        XCTAssertEqual(queue.items(for: Fixture.bookId).map(\.body), ["this book"])
    }

    // ---- the retry decision ------------------------------------------------------------------

    func testA4xxIsAPermanentRefusal() {
        let queue = TextSendQueue(defaults: defaults)

        // A validation error, a rate limit, a deleted book: retrying cannot change the answer, so
        // the bubble is dropped rather than left retrying forever.
        for code in [400, 403, 404, 422, 429, 499] {
            XCTAssertTrue(queue.isPermanentRefusal(APIError.serverError(code)), "HTTP \(code)")
        }
    }

    func testAnOutageIsNotAPermanentRefusal() {
        let queue = TextSendQueue(defaults: defaults)

        // These are transient. Dropping the message here is the failure mode #146 exists to
        // prevent: the send vanishes and the user never learns it did not arrive.
        XCTAssertFalse(queue.isPermanentRefusal(URLError(.notConnectedToInternet)))
        XCTAssertFalse(queue.isPermanentRefusal(URLError(.timedOut)))
        XCTAssertFalse(queue.isPermanentRefusal(APIError.serverError(500)))
        XCTAssertFalse(queue.isPermanentRefusal(APIError.serverError(503)))
    }
}
