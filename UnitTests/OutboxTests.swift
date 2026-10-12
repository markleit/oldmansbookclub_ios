import XCTest
@testable import OldMansBookClub

/// #204 (U1, U7, U8) — the outbox: every unsent message on disk, the tap times that order the chat,
/// and taking over what 2.1 had queued.
@MainActor
final class OutboxTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OutboxTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func outbox() -> Outbox { Outbox(directory: root.appendingPathComponent("Outbox")) }

    private func text(_ body: String, sentAt: Date = Date()) -> SendItem {
        SendItem(id: UUID(), bookId: UUID(), clubId: UUID(), kind: .text, sentAt: sentAt, body: body)
    }

    // MARK: - Durability (U1)

    func testItemsSurviveARelaunch() {
        let first = outbox()
        var item = text("survives a force-quit")
        item.status = .waiting
        item.attempts = 3
        first.add(item)

        let reopened = outbox()

        XCTAssertEqual(reopened.items, [item])
    }

    func testUpdatesArePersisted() {
        let box = outbox()
        let item = text("x")
        box.add(item)
        box.update(item.id) { $0.status = .refused; $0.refusedReason = "nope" }

        XCTAssertEqual(outbox().item(item.id)?.refusedReason, "nope")
    }

    func testRemovingAnItemDeletesItsFile() throws {
        let box = outbox()
        let name = try box.importData(Data([1, 2, 3]), extension: "jpg")
        var item = text("photo")
        item.fileName = name
        box.add(item)

        box.remove(item.id, fileGrace: 0)

        XCTAssertTrue(box.items.isEmpty)
        XCTAssertFalse(box.fileExists(name))
    }

    func testFilesNothingRefersToAreSweptOnLaunch() throws {
        // Left behind by a crash between removing an item and deleting its file.
        let box = outbox()
        let orphan = try box.importData(Data([9]), extension: "m4a")
        let kept = try box.importData(Data([8]), extension: "m4a")
        var item = text("voice")
        item.fileName = kept
        box.add(item)

        let reopened = outbox()

        XCTAssertFalse(reopened.fileExists(orphan))
        XCTAssertTrue(reopened.fileExists(kept))
    }

    func testASentVideoTakesBothItsOriginalAndItsCompressedCopyWithIt() throws {
        // U9: the original is kept until the video is sent (PR 5) — then both go.
        let box = outbox()
        let original = try box.importData(Data([1]), extension: "mp4")
        let compressed = try box.importData(Data([2]), extension: "mp4")
        var item = text("video")
        item.fileName = compressed
        item.originalFileName = original
        box.add(item)

        box.remove(item.id, fileGrace: 0)

        XCTAssertFalse(box.fileExists(original))
        XCTAssertFalse(box.fileExists(compressed))
    }

    func testTheLaunchSweepKeepsAVideosOriginalWhileItsUnsent() throws {
        let box = outbox()
        let original = try box.importData(Data([1]), extension: "mp4")
        let compressed = try box.importData(Data([2]), extension: "mp4")
        var item = text("video")
        item.fileName = compressed
        item.originalFileName = original
        box.add(item)

        let reopened = outbox()

        XCTAssertTrue(reopened.fileExists(original))
        XCTAssertTrue(reopened.fileExists(compressed))
    }

    // MARK: - Tap times (U7)

    func testTapTimesAreStrictlyIncreasingEvenInTheSameMillisecond() {
        let box = outbox()
        let now = Date()
        let times = (0..<5).map { _ in box.nextSentAt(now: now) }
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(Set(times).count, 5)
    }

    func testTapTimesNeverGoBackwardsWhenTheClockDoes() {
        let box = outbox()
        let first = box.nextSentAt(now: Date())
        let afterClockStep = box.nextSentAt(now: first.addingTimeInterval(-3600))
        XCTAssertGreaterThan(afterClockStep, first)
    }

    func testTheLastTapTimeSurvivesARelaunch() {
        let first = outbox().nextSentAt(now: Date())
        XCTAssertGreaterThan(outbox().nextSentAt(now: first.addingTimeInterval(-60)), first)
    }

    // MARK: - Taking over 2.1's queues (U8)

    private struct LegacyText: Encodable {
        let clientId: UUID; let bookId: UUID; let clubId: UUID; let body: String
        let parentMessageId: UUID?; let queuedAt: Date; let seq: Int?
    }

    private struct LegacyMedia: Encodable {
        let id: UUID; let bookId: UUID; let clubId: UUID; let kind: String; let fileName: String
        let contentType: String; let durationSeconds: Int?; var uploadedMediaUrl: String?
        let retryCount: Int; let parentMessageId: UUID?; let seq: Int?
    }

    private func legacyDefaults() -> UserDefaults {
        let name = "OutboxTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testEverything21HadQueuedIsTakenOverInSendOrder() throws {
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let pendingMedia = support.appendingPathComponent("PendingMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: pendingMedia, withIntermediateDirectories: true)
        let defaults = legacyDefaults()
        let book = UUID(), club = UUID(), parent = UUID()

        // seq 2: a text typed after the photo; seq 1: the photo, its blob already uploaded;
        // seq 3: a voice message whose upload never started.
        let text = LegacyText(clientId: UUID(), bookId: book, clubId: club, body: "after the photo",
                              parentMessageId: parent, queuedAt: Date(timeIntervalSince1970: 2_000), seq: 2)
        defaults.set(try JSONEncoder().encode([text]), forKey: "pendingTextSends")
        try Data([1]).write(to: pendingMedia.appendingPathComponent("p.jpg"))
        try Data([2]).write(to: pendingMedia.appendingPathComponent("v.m4a"))
        let photo = LegacyMedia(id: UUID(), bookId: book, clubId: club, kind: "photo", fileName: "p.jpg",
                                contentType: "image/jpeg", durationSeconds: nil,
                                uploadedMediaUrl: "https://blob/club/p.jpg", retryCount: 2, parentMessageId: nil, seq: 1)
        let voice = LegacyMedia(id: UUID(), bookId: book, clubId: club, kind: "voice", fileName: "v.m4a",
                                contentType: "audio/mp4", durationSeconds: 12, uploadedMediaUrl: nil,
                                retryCount: 0, parentMessageId: nil, seq: 3)
        try JSONEncoder().encode([voice, photo]).write(to: support.appendingPathComponent("media_queue.json"))

        let box = outbox()
        let taken = box.migrateLegacy(defaults: defaults, supportDirectory: support)

        XCTAssertEqual(taken, 3)
        let byTapTime = box.items.sorted { $0.sentAt < $1.sentAt }
        XCTAssertEqual(byTapTime.map(\.id), [photo.id, text.clientId, voice.id], "2.1's send order is kept")
        XCTAssertEqual(byTapTime[0].mediaUrl, "https://blob/club/p.jpg", "an uploaded blob isn't uploaded again")
        XCTAssertEqual(byTapTime[1].body, "after the photo")
        XCTAssertEqual(byTapTime[1].parentMessageId, parent)
        XCTAssertEqual(byTapTime[2].durationSeconds, 12)
        XCTAssertTrue(box.fileExists("v.m4a"), "the media moved into the outbox")

        // The old stores are gone, so this runs once.
        XCTAssertNil(defaults.data(forKey: "pendingTextSends"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("media_queue.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingMedia.path))
        XCTAssertEqual(box.migrateLegacy(defaults: defaults, supportDirectory: support), 0)
    }

    func testALegacyMediaItemWhoseFileWasPurgedIsDropped() throws {
        let support = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let gone = LegacyMedia(id: UUID(), bookId: UUID(), clubId: UUID(), kind: "photo", fileName: "gone.jpg",
                               contentType: "image/jpeg", durationSeconds: nil, uploadedMediaUrl: nil,
                               retryCount: 0, parentMessageId: nil, seq: 1)
        try JSONEncoder().encode([gone]).write(to: support.appendingPathComponent("media_queue.json"))

        let box = outbox()

        XCTAssertEqual(box.migrateLegacy(defaults: legacyDefaults(), supportDirectory: support), 0)
        XCTAssertTrue(box.items.isEmpty)
    }

    func testMigratingWithNothingQueuedIsHarmless() {
        let box = outbox()
        XCTAssertEqual(box.migrateLegacy(defaults: legacyDefaults(), supportDirectory: root), 0)
        XCTAssertTrue(box.items.isEmpty)
    }
}
