import Combine
import XCTest
@testable import OldMansBookClub

private extension Array {
    /// Tests read submissions and items through this, so a regression that never made one fails by
    /// name (XCTUnwrap) instead of crashing the test process — which, on a simulator, can stall the
    /// whole run.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// #204 (U3–U6) — the SendEngine with a fake transport, fake tokens, a hand-driven clock and
/// hand-fired timers: every path a send can take, without a network or a simulator UI.
@MainActor
final class SendEngineTests: XCTestCase {

    // MARK: - Fakes

    final class FakeTransport: SendTransport {
        var onBackgroundResult: ((SendTaskKey, SendResponse) -> Void)?
        var background: [(key: SendTaskKey, request: URLRequest, bodyFile: URL)] = []
        var direct: [URLRequest] = []
        var cancelled: [UUID] = []
        var held: [SendTaskKey] = []
        /// How a direct send answers; default: never in time (the background copy decides).
        var directResponse: (URLRequest) async -> SendResponse = { _ in
            try? await Task.sleep(for: .seconds(3600))
            return SendResponse(error: URLError(.timedOut))
        }
        var onSubmit: ((SendTaskKey) -> Void)?

        func submitBackground(_ key: SendTaskKey, request: URLRequest, bodyFile: URL) {
            background.append((key, request, bodyFile))
            onSubmit?(key)
        }
        func sendDirect(_ request: URLRequest, body: Data?, bodyFile: URL?) async -> SendResponse {
            direct.append(request)
            return await directResponse(request)
        }
        func cancelBackground(itemId: UUID) { cancelled.append(itemId) }
        func backgroundTaskKeys() async -> [SendTaskKey] { held }
        func cancelAll() {}

        /// Report a result for the index-th background submission — a clear test failure, not a
        /// crash, if it was never made (so a regression reads as a failed assertion).
        func finish(_ index: Int, _ response: SendResponse, file: StaticString = #filePath, line: UInt = #line) {
            guard background.indices.contains(index) else {
                return XCTFail("no background submission #\(index) (only \(background.count))", file: file, line: line)
            }
            onBackgroundResult?(background[index].key, response)
        }
    }

    private var root: URL!
    private var transport: FakeTransport!
    private var now = Date(timeIntervalSince1970: 1_000_000)
    private var appActive = true
    private var network = true
    private var tokenCalls: [TimeInterval] = []
    private var rejections = 0
    private var tokenAfterRejectionResult: APIClient.SendToken = .token("fresh-token")
    /// When set, a token refresh waits here until the test resumes it.
    private var refreshGate: (() async -> Void)?
    private var wakes: [(delay: TimeInterval, action: @MainActor () -> Void, cancelled: Bool)] = []
    private var cached: [(UUID, Message)] = []
    private var confirmations: [SendConfirmation] = []
    private var subscriptions: Set<AnyCancellable> = []
    private let book = UUID(), club = UUID(), me = UUID()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SendEngineTests-\(UUID().uuidString)")
        transport = FakeTransport()
        confirmations = []
        cached = []
        wakes = []
        tokenCalls = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func outbox() -> Outbox { Outbox(directory: root.appendingPathComponent("Outbox")) }

    private func makeEngine(outbox box: Outbox? = nil, timing: SendTiming = SendTiming()) -> SendEngine {
        let env = SendEnvironment(
            now: { [unowned self] in self.now },
            jitter: { 0 },
            isAppActive: { [unowned self] in self.appActive },
            hasNetwork: { [unowned self] in self.network },
            baseURL: { URL(string: "https://api.test")! },
            deviceId: { "device-1" },
            myUserId: { [unowned self] in self.me },
            token: { [unowned self] validFor in self.tokenCalls.append(validFor); return .token("tok") },
            tokenAfterRejection: { [unowned self] in
                self.rejections += 1
                if let gate = self.refreshGate { await gate() }
                return self.tokenAfterRejectionResult
            },
            uploadLink: { _, _ in (URL(string: "https://blob.test/v.mp4?sig=w")!, "https://blob.test/v.mp4") },
            schedule: { [unowned self] delay, action in
                let index = self.wakes.count
                self.wakes.append((delay, action, false))
                return { [weak self] in self?.wakes[index].cancelled = true }
            },
            cacheConfirmed: { [unowned self] book, message in self.cached.append((book, message)) })
        let engine = SendEngine(outbox: box ?? outbox(), transport: transport, environment: env, timing: timing)
        engine.confirmations.sink { [unowned self] in self.confirmations.append($0) }.store(in: &subscriptions)
        return engine
    }

    private func started(_ engine: SendEngine) async -> SendEngine {
        await engine.start()
        return engine
    }

    /// Lets the engine's async hops (token fetch → submit) run.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func delivered(_ clientId: UUID, body: String = "hi") -> SendResponse {
        let message = Message(id: UUID(), clubId: club, senderId: me, senderName: "Mark", type: .text,
                              body: body, mediaUrl: nil, durationSeconds: nil, sentAt: now, clientId: clientId)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return SendResponse(status: 200, body: try! encoder.encode(message))
    }

    private func status(_ code: Int, error: String? = nil, retryAfter: String? = nil) -> SendResponse {
        SendResponse(status: code, body: error.map { try! JSONSerialization.data(withJSONObject: ["error": $0]) },
                     retryAfter: retryAfter)
    }

    private func fireWakes(upTo seconds: TimeInterval) {
        let due = wakes.indices.filter { !wakes[$0].cancelled && wakes[$0].delay <= seconds }
        for index in due {
            wakes[index].cancelled = true
            wakes[index].action()
        }
    }

    private func json(_ request: URLRequest, bodyFile: URL) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: bodyFile))) as? [String: Any] ?? [:]
    }

    // MARK: - U3: submission

    func testATextIsOnDiskBeforeAnythingIsSent() async throws {
        let box = outbox()
        var onDiskAtSubmit: Bool?
        transport.onSubmit = { [unowned self] key in
            onDiskAtSubmit = Outbox(directory: self.root.appendingPathComponent("Outbox")).item(key.itemId) != nil
        }
        let engine = await started(makeEngine(outbox: box))

        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        XCTAssertEqual(onDiskAtSubmit, true, "a force-quit at the moment of sending must not lose the message")
    }

    func testATextGoesThroughIOSAndDirectlyAtOnce() async throws {
        let engine = await started(makeEngine())

        let item = engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        XCTAssertEqual(transport.background.count, 1)
        XCTAssertEqual(transport.direct.count, 1, "text never waits on iOS's schedule while the app is open")
        let body = json(try XCTUnwrap(transport.background[safe: 0]).request, bodyFile: try XCTUnwrap(transport.background[safe: 0]).bodyFile)
        XCTAssertEqual(body["client_id"] as? String, item.id.uuidString.lowercased())
        XCTAssertEqual(body["body"] as? String, "hello")
        XCTAssertNotNil(body["sent_at"])
        XCTAssertEqual(try XCTUnwrap(transport.background[safe: 0]).request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testTheFirstCopyToLandWinsAndTheOtherIsDropped() async throws {
        let engine = await started(makeEngine())
        let item = engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        transport.finish(0, delivered(item.id))
        transport.finish(0, delivered(item.id))   // the other copy, landing late

        XCTAssertEqual(confirmations.count, 1, "one bubble, not two")
        XCTAssertTrue(transport.cancelled.contains(item.id), "the other copy is cancelled")
        XCTAssertTrue(engine.items.isEmpty)
    }

    func testVoiceGoesThroughIOSFirstAndDirectlyOnlyAfterTheNudge() async throws {
        let engine = await started(makeEngine())
        let name = try engine.files.importData(Data([1, 2, 3]), extension: "m4a")

        engine.enqueueMedia(.voice, bookId: book, clubId: club, fileName: name, contentType: "audio/mp4",
                            durationSeconds: 7, replyTo: nil)
        await settle()

        XCTAssertEqual(transport.background.count, 1)
        XCTAssertEqual(transport.direct.count, 0, "a media file isn't uploaded twice unless it has to be")
        XCTAssertEqual(try XCTUnwrap(transport.background[safe: 0]).request.value(forHTTPHeaderField: "Content-Type"), "audio/mp4")
        XCTAssertEqual(try XCTUnwrap(transport.background[safe: 0]).bodyFile.lastPathComponent, name)

        fireWakes(upTo: 3)   // the direct nudge
        await settle()
        XCTAssertEqual(transport.direct.count, 1)
    }

    func testNothingGoesDirectlyWhileTheAppIsBackgrounded() async throws {
        let engine = await started(makeEngine())
        appActive = false

        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        XCTAssertEqual(transport.background.count, 1)
        XCTAssertEqual(transport.direct.count, 0)
    }

    func testMessagesGoInParallelNotInALine() async throws {
        let engine = await started(makeEngine())

        for i in 0..<3 { engine.enqueueText(bookId: book, clubId: club, body: "\(i)", replyTo: nil) }
        await settle()

        XCTAssertEqual(transport.background.count, 3, "nothing waits for the message before it")
        let times = engine.items.map(\.sentAt)
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(Set(times).count, 3, "tap times are distinct, so the chat order is the tap order")
    }

    func testATriggerStormSendsEachMessageOnce() async throws {
        let engine = await started(makeEngine())
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        engine.networkBecameReachable()
        engine.appBecameActive()
        engine.chatOpened()
        engine.serverReachable()
        await settle()

        XCTAssertEqual(transport.background.count, 1)
    }

    // MARK: - U4: auth and limits

    func testATokenIsRefreshedIfItExpiresTooSoonForIOSToHoldTheRequest() async throws {
        let engine = await started(makeEngine())
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()
        XCTAssertEqual(tokenCalls, [600])
    }

    func testARefusedTokenIsRefreshedAndTheMessageResent() async throws {
        let engine = await started(makeEngine())
        let item = engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        transport.finish(0, status(401))
        await settle()

        XCTAssertEqual(rejections, 1)
        XCTAssertEqual(transport.background.count, 2, "resent at once with the new token")
        XCTAssertEqual(try XCTUnwrap(transport.background[safe: 1]).key.attempt, 2)
        XCTAssertEqual(engine.items.first?.id, item.id)
    }

    func testARetryDuringTheTokenRefreshIsNotFollowedByASecondOverlappingAttempt() async throws {
        // Both copies get 401: the first starts a refresh, the second puts the message on the
        // clock, and the clock fires before the refresh returns. The refresh must not then send
        // another attempt on top of the one the clock already sent (found by a flaky CI run: one
        // overlapping attempt hit a refusal while the other got through).
        var release: CheckedContinuation<Void, Never>?
        refreshGate = { await withCheckedContinuation { release = $0 } }
        transport.directResponse = { _ in SendResponse(status: 401) }
        let engine = await started(makeEngine())

        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()
        transport.finish(0, status(401))   // the background copy; the direct copy's 401 is back too
        await settle()
        XCTAssertEqual(rejections, 1, "one refresh in progress")

        transport.directResponse = { _ in try? await Task.sleep(for: .seconds(3600)); return SendResponse(status: 503) }
        now = now.addingTimeInterval(5)
        engine.pump("retry clock")         // attempt 2, while the refresh is still out
        await settle()
        let afterClock = transport.background.count
        XCTAssertEqual(transport.background.last?.key.attempt, 2)

        release?.resume()
        await settle()

        XCTAssertEqual(transport.background.count, afterClock, "the refresh added a third, overlapping attempt")
    }

    func testASecondRefusedTokenWaitsOnTheClock() async throws {
        let engine = await started(makeEngine())
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()
        transport.finish(0, status(401))
        await settle()

        transport.finish(1, status(401))
        await settle()

        XCTAssertEqual(rejections, 1)
        XCTAssertEqual(engine.items.first?.status, .waiting)
    }

    func testRateLimitedWaitsExactlyAsLongAsTheServerSays() async throws {
        let engine = await started(makeEngine())
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        transport.finish(0, status(429, error: "Slow down", retryAfter: "20"))
        XCTAssertEqual(engine.items.first?.status, .waiting)

        now = now.addingTimeInterval(19)
        engine.pump("test")
        await settle()
        XCTAssertEqual(transport.background.count, 1, "not before Retry-After")

        now = now.addingTimeInterval(1)
        engine.pump("test")
        await settle()
        XCTAssertEqual(transport.background.count, 2)
    }

    // MARK: - U5: refusals and delete

    func testARefusalShowsTheReasonAndIsNeverRetried() async throws {
        let engine = await started(makeEngine())
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        transport.finish(0, status(400, error: "Not a member of this club."))
        for _ in 0..<3 {
            now = now.addingTimeInterval(120)
            engine.appBecameActive()
            await settle()
        }

        XCTAssertEqual(engine.items.first?.status, .refused)
        XCTAssertEqual(engine.displayState(of: try XCTUnwrap(engine.items.first)), .refused("Not a member of this club."))
        XCTAssertEqual(transport.background.count, 1)
    }

    func testDeletingAnUnsentMessageCancelsIt() async throws {
        let engine = await started(makeEngine())
        let item = engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        engine.delete(item.id)

        XCTAssertTrue(engine.items.isEmpty)
        XCTAssertTrue(transport.cancelled.contains(item.id))
        XCTAssertNil(outbox().item(item.id))
    }

    func testAMessageDeletedOnItsWayThatLandsAnywayIsShownAsSent() async throws {
        // D1 — it exists on the server; hiding it would leave the sender out of step with everyone.
        let engine = await started(makeEngine())
        let item = engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()
        engine.delete(item.id)

        transport.finish(0, delivered(item.id))

        XCTAssertEqual(confirmations.map(\.clientId), [item.id])
        XCTAssertEqual(confirmations.first?.bookId, book)
    }

    // MARK: - The shared clock (U2 through the engine)

    func testWhenTheServerIsDownOneProbeAtATimeThenEverythingFollowsIt() async throws {
        let engine = await started(makeEngine())
        transport.directResponse = { _ in SendResponse(status: 503) }
        let items = (0..<3).map { engine.enqueueText(bookId: book, clubId: club, body: "\($0)", replyTo: nil) }
        await settle()
        for i in 0..<3 { transport.finish(i, status(503)) }
        await settle()
        XCTAssertTrue(engine.items.allSatisfy { $0.status == .waiting })
        XCTAssertEqual(wakes.last { !$0.cancelled }?.delay, 1, "three failures in one round move the clock once")

        now = now.addingTimeInterval(1)
        engine.pump("retry clock")
        await settle()
        XCTAssertEqual(transport.background.count, 4, "one probe per tick while the server's down, not three")
        XCTAssertEqual(try XCTUnwrap(transport.background[safe: 3]).key.itemId, items[0].id, "the oldest goes first")

        transport.finish(3, delivered(items[0].id))
        await settle()
        XCTAssertEqual(Set(transport.background.dropFirst(4).map(\.key.itemId)), [items[1].id, items[2].id],
                       "the probe landed: the other two go at once")
    }

    func testWhileIOSHoldsItsCopyAFailingMessageStillShowsWaitingAndIsRetriedDirectly() async throws {
        // The server is down but the phone has a network: iOS can sit on its background copy for a
        // long time. The bubble must still turn to "waiting", and the engine must keep retrying
        // directly on its own clock rather than wait on iOS's schedule.
        var directCalls = 0
        transport.directResponse = { _ in directCalls += 1; return SendResponse(status: 503) }
        let engine = await started(makeEngine())
        let item = engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()
        XCTAssertEqual(directCalls, 1)
        XCTAssertEqual(engine.items.first?.status, .inFlight, "iOS's copy is still out")

        now = now.addingTimeInterval(30)
        XCTAssertEqual(engine.displayState(of: try XCTUnwrap(engine.items.first)), .waiting)

        transport.directResponse = { [unowned self] _ in directCalls += 1; return self.delivered(item.id) }
        engine.pump("retry clock")
        await settle()

        XCTAssertEqual(directCalls, 2, "retried directly on the shared clock")
        XCTAssertTrue(engine.items.isEmpty)
        XCTAssertTrue(transport.cancelled.contains(item.id), "iOS's copy is dropped once it's delivered")
    }

    func testOfflineAtTapShowsWaitingAndGoesTheMomentTheNetworkIsBack() async throws {
        network = false
        let engine = await started(makeEngine())

        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()
        XCTAssertEqual(transport.background.count, 0)
        XCTAssertEqual(engine.displayState(of: try XCTUnwrap(engine.items.first)), .waiting)

        network = true
        engine.networkBecameReachable()
        await settle()
        XCTAssertEqual(transport.background.count, 1)
    }

    func testSendingTurnsIntoWaitingAfterThirtySecondsOfFailures() async throws {
        let engine = await started(makeEngine())
        transport.directResponse = { _ in SendResponse(status: 503) }
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()
        transport.finish(0, status(503))
        await settle()

        XCTAssertEqual(engine.displayState(of: try XCTUnwrap(engine.items.first)), .sending)
        now = now.addingTimeInterval(30)
        XCTAssertEqual(engine.displayState(of: try XCTUnwrap(engine.items.first)), .waiting)
    }

    func testSendNowGoesImmediatelyEvenWhileBackingOff() async throws {
        let engine = await started(makeEngine())
        transport.directResponse = { _ in SendResponse(status: 503) }
        let item = engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()
        transport.finish(0, status(503))
        await settle()
        let before = transport.background.count

        engine.sendNow(item.id)
        await settle()

        XCTAssertEqual(transport.background.count, before + 1)
    }

    // MARK: - U6: across launches, and other channels

    func testOnRelaunchATransferIOSStillHoldsIsWaitedForAndTheRestResent() async throws {
        let box = outbox()
        let held = SendItem(id: UUID(), bookId: book, clubId: club, kind: .text, sentAt: now, body: "held", status: .inFlight)
        let lost = SendItem(id: UUID(), bookId: book, clubId: club, kind: .text, sentAt: now.addingTimeInterval(1),
                            body: "lost", status: .inFlight)
        box.add(held)
        box.add(lost)
        transport.held = [SendTaskKey(itemId: held.id, attempt: 0, step: .post)]

        let engine = await started(makeEngine(outbox: box))
        await settle()

        XCTAssertEqual(transport.background.map(\.key.itemId), [lost.id], "no second copy of what iOS still holds")
        transport.onBackgroundResult?(transport.held[0], delivered(held.id))
        XCTAssertEqual(confirmations.map(\.clientId), [held.id], "the previous run's transfer still confirms it")
        _ = engine
    }

    func testAConfirmationUpdatesTheSavedChatEvenWithNoChatOpen() async throws {
        let engine = await started(makeEngine())
        let item = engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        transport.finish(0, delivered(item.id))

        XCTAssertEqual(cached.map(\.0), [book])
    }

    func testTheSignalREchoCountsAsDelivered() async throws {
        let engine = await started(makeEngine())
        let item = engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()
        let echo = Message(id: UUID(), clubId: club, senderId: me, senderName: "Mark", type: .text,
                           body: "hello", mediaUrl: nil, durationSeconds: nil, sentAt: now, clientId: item.id)

        engine.confirm(clientId: item.id, message: echo)

        XCTAssertTrue(engine.items.isEmpty)
        XCTAssertTrue(transport.cancelled.contains(item.id))
        XCTAssertEqual(confirmations.count, 1)
    }

    // MARK: - Video and missing files

    func testAVideoUploadsItsBlobThenPostsTheURL() async throws {
        let engine = await started(makeEngine())
        let name = try engine.files.importData(Data([7, 7]), extension: "mp4")

        let item = engine.enqueueMedia(.video, bookId: book, clubId: club, fileName: name, contentType: "video/mp4",
                                       durationSeconds: nil, replyTo: nil)
        await settle()

        XCTAssertEqual(transport.background.count, 1)
        XCTAssertEqual(try XCTUnwrap(transport.background[safe: 0]).request.httpMethod, "PUT")
        XCTAssertEqual(try XCTUnwrap(transport.background[safe: 0]).request.value(forHTTPHeaderField: "x-ms-blob-type"), "BlockBlob")

        transport.finish(0, SendResponse(status: 201))
        await settle()

        XCTAssertEqual(transport.background.count, 2)
        let post = json(try XCTUnwrap(transport.background[safe: 1]).request, bodyFile: try XCTUnwrap(transport.background[safe: 1]).bodyFile)
        XCTAssertEqual(post["media_url"] as? String, "https://blob.test/v.mp4")
        XCTAssertEqual(post["type"] as? String, "Video")
        XCTAssertEqual(post["client_id"] as? String, item.id.uuidString.lowercased())
    }

    func testAMessageWhoseFileIsGoneIsRefusedNotSilentlyDropped() async throws {
        let engine = await started(makeEngine())
        let name = try engine.files.importData(Data([1]), extension: "jpg")
        try FileManager.default.removeItem(at: engine.files.fileURL(name))

        engine.enqueueMedia(.photo, bookId: book, clubId: club, fileName: name, contentType: "image/jpeg",
                            durationSeconds: nil, replyTo: nil)
        await settle()

        guard case .refused(let reason) = engine.displayState(of: try XCTUnwrap(engine.items.first)) else { return XCTFail("not refused") }
        XCTAssertTrue(reason.contains("missing"))
    }
}

/// #204 — the requests themselves, against the API's contract (PR 1).
final class SendRequestBuilderTests: XCTestCase {
    private let base = URL(string: "https://api.test")!
    private let sentAt = Date(timeIntervalSince1970: 1_760_000_000.123)

    func testVoiceIsTheFileAsTheBodyWithEverythingElseInTheQuery() throws {
        let parent = UUID()
        let item = SendItem(id: UUID(), bookId: UUID(), clubId: UUID(), kind: .voice, sentAt: sentAt,
                            fileName: "v.m4a", durationSeconds: 42, parentMessageId: parent)
        let file = URL(fileURLWithPath: "/tmp/v.m4a")

        let built = SendRequestBuilder.post(item, baseURL: base, token: "tok", deviceId: "dev", fileURL: file)

        XCTAssertEqual(built.bodyFile, file)
        XCTAssertNil(built.jsonBody)
        XCTAssertEqual(built.request.value(forHTTPHeaderField: "Content-Type"), "audio/mp4")
        let query = URLComponents(url: built.request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let value = { (name: String) in query.first { $0.name == name }?.value }
        XCTAssertEqual(value("client_id"), item.id.uuidString.lowercased())
        XCTAssertEqual(value("duration_seconds"), "42")
        XCTAssertEqual(value("parent_message_id"), parent.uuidString.lowercased())
        XCTAssertEqual(value("device_id"), "dev")
        XCTAssertEqual(value("sent_at"), "2025-10-09T08:53:20.123Z")
        XCTAssertEqual(built.request.url?.path, "/books/\(item.bookId.uuidString.lowercased())/messages")
    }

    func testAPhotoWhoseBlobIsUploadedPostsJSONWithTheURL() throws {
        let item = SendItem(id: UUID(), bookId: UUID(), clubId: UUID(), kind: .photo, sentAt: sentAt,
                            fileName: "p.jpg", mediaUrl: "https://blob/p.jpg")

        let built = SendRequestBuilder.post(item, baseURL: base, token: "tok", deviceId: nil, fileURL: URL(fileURLWithPath: "/tmp/p.jpg"))

        XCTAssertNil(built.bodyFile)
        let json = try JSONSerialization.jsonObject(with: built.jsonBody!) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "Photo")
        XCTAssertEqual(json["media_url"] as? String, "https://blob/p.jpg")
    }

    func testAForwardCarriesTheSavedMessageAndAClientId() throws {
        let saved = UUID()
        let item = SendItem(id: UUID(), bookId: UUID(), clubId: UUID(), kind: .forward, sentAt: sentAt, forwardMessageId: saved)

        let built = SendRequestBuilder.post(item, baseURL: base, token: "tok", deviceId: nil, fileURL: nil)

        let json = try JSONSerialization.jsonObject(with: built.jsonBody!) as! [String: Any]
        XCTAssertEqual(json["forward_message_id"] as? String, saved.uuidString.lowercased())
        XCTAssertEqual(json["client_id"] as? String, item.id.uuidString.lowercased())
    }
}
