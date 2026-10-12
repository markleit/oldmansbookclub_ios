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
        var onBackgroundProgress: ((SendTaskKey, Int64, Int64) -> Void)?
        var background: [(key: SendTaskKey, request: URLRequest, bodyFile: URL, notBefore: Date?)] = []
        var direct: [URLRequest] = []
        /// The client id of each direct JSON send, in order.
        var directClientIds: [String] = []
        /// Video reservations (design v2) — direct requests too, kept apart from the message sends.
        var reservations: [(request: URLRequest, body: [String: Any])] = []
        /// How a reservation answers; default: a create-only link to a new blob.
        var reserveResponse: () async -> SendResponse = {
            SendResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: [
                "upload_url": "https://blob.test/v.mp4?sig=create", "media_url": "https://blob.test/v.mp4"]))
        }
        var cancelled: [UUID] = []
        var held: [SendTaskKey] = []
        /// How a direct send answers; default: never in time (the background copy decides).
        var directResponse: (URLRequest) async -> SendResponse = { _ in
            try? await Task.sleep(for: .seconds(3600))
            return SendResponse(error: URLError(.timedOut))
        }
        var onSubmit: ((SendTaskKey) -> Void)?

        func submitBackground(_ key: SendTaskKey, request: URLRequest, bodyFile: URL, notBefore: Date?) {
            background.append((key, request, bodyFile, notBefore))
            onSubmit?(key)
        }
        func sendDirect(_ request: URLRequest, body: Data?, bodyFile: URL?) async -> SendResponse {
            if request.url?.path.hasSuffix("/messages/video") == true {
                reservations.append((request, body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]))
                return await reserveResponse()
            }
            direct.append(request)
            if let id = body.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["client_id"] as? String {
                directClientIds.append(id)
            }
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
    private var tokenCalls = 0
    private var tokenResult: APIClient.SendToken = .token("tok")
    /// When set, getting a token waits here (a refresh that takes a while).
    private var tokenGate: (() async -> Void)?
    /// Everything the engine told continued processing (design v2).
    private var videoWork: [VideoWork] = []
    /// Videos handed to the compressor, and what it does: by default a smaller copy.
    private var compressed: [URL] = []
    private var compressGate: (() async -> Void)?
    /// Every reminder the engine set (nil = cancelled), in order.
    private var reminders: [ReminderPlan?] = []
    private var compression: (URL) -> VideoCompression = { source in
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try? Data([1]).write(to: out)
        return .compressed(out)
    }
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
        tokenCalls = 0
        videoWork = []
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
            token: { [unowned self] in
                self.tokenCalls += 1
                if let gate = self.tokenGate { await gate() }
                return self.tokenResult
            },
            tokenAfterRejection: { [unowned self] in
                self.rejections += 1
                if let gate = self.refreshGate { await gate() }
                return self.tokenAfterRejectionResult
            },
            compressVideo: { [unowned self] source, progress in
                self.compressed.append(source)
                progress(0.5)
                if let gate = self.compressGate { await gate() }
                return self.compression(source)
            },
            videoWork: { [unowned self] in self.videoWork.append($0) },
            schedule: { [unowned self] delay, action in
                let index = self.wakes.count
                self.wakes.append((delay, action, false))
                return { [weak self] in self?.wakes[index].cancelled = true }
            },
            cacheConfirmed: { [unowned self] book, message in self.cached.append((book, message)) },
            reminder: { [unowned self] plan in self.reminders.append(plan) })
        let engine = SendEngine(outbox: box ?? outbox(), transport: transport, environment: env, timing: timing)
        engine.shareInbox = nil   // not the simulator's real App Group inbox (share tests set their own)
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

    func testR7EverySendCarriesTheSendTokenOnBothCopies() async throws {
        // Design v2 — the week-long send token rides on the carrier, so a message iOS holds for
        // days can't arrive with an expired token. (Which token, renewed when: APIClient.sendToken.)
        tokenResult = .token("send-token")
        let engine = await started(makeEngine())
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()
        XCTAssertEqual(tokenCalls, 1)
        XCTAssertEqual(transport.background.first?.request.value(forHTTPHeaderField: "Authorization"), "Bearer send-token")
        XCTAssertEqual(transport.direct.first?.value(forHTTPHeaderField: "Authorization"), "Bearer send-token")
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

    func testASecondRefusedTokenIsRetriedOnTheClockNotRenewedInALoop() async throws {
        let engine = await started(makeEngine())
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()
        transport.finish(0, status(401))
        await settle()

        transport.finish(1, status(401))
        await settle()

        XCTAssertEqual(rejections, 1, "renewed once")
        XCTAssertEqual(transport.background.count, 3, "a new carrier, held until the clock is due")
        XCTAssertEqual(try XCTUnwrap(transport.background[safe: 2]).notBefore, now.addingTimeInterval(1))
    }
    func testRateLimitedWaitsExactlyAsLongAsTheServerSays() async throws {
        transport.directResponse = { [unowned self] _ in self.status(429, error: "Slow down", retryAfter: "20") }
        let engine = await started(makeEngine())
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()   // the direct copy: 429

        XCTAssertEqual(transport.background.count, 2, "its carrier replaced, held by iOS until Retry-After")
        XCTAssertEqual(try XCTUnwrap(transport.background[safe: 1]).notBefore, now.addingTimeInterval(20))
        let direct = transport.direct.count

        now = now.addingTimeInterval(19)
        engine.pump("test")
        await settle()
        XCTAssertEqual(transport.direct.count, direct, "not before Retry-After")

        now = now.addingTimeInterval(1)
        engine.pump("test")
        await settle()
        XCTAssertEqual(transport.direct.count, direct + 1)
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
        XCTAssertEqual(transport.background.count, 6, "each failed carrier replaced at once: every message keeps one")
        XCTAssertTrue(transport.background.dropFirst(3).allSatisfy { $0.notBefore == now.addingTimeInterval(1) },
                      "held by iOS until the clock is due")
        XCTAssertEqual(wakes.last { !$0.cancelled }?.delay, 1, "three failures in one round move the clock once")
        let before = transport.directClientIds.count

        now = now.addingTimeInterval(1)
        engine.pump("retry clock")
        await settle()
        XCTAssertEqual(Array(transport.directClientIds.dropFirst(before)), [items[0].id.uuidString.lowercased()],
                       "one probe per tick while the server's down, not three — the oldest")

        now = now.addingTimeInterval(2)
        transport.directResponse = { [unowned self] _ in self.delivered(UUID()) }
        engine.pump("retry clock")
        await settle()
        XCTAssertEqual(Set(transport.directClientIds.dropFirst(before + 2)),
                       [items[1].id.uuidString.lowercased(), items[2].id.uuidString.lowercased()],
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

    func testOfflineAtTapIsHandedToIOSAndShowsWaiting() async throws {
        network = false
        let engine = await started(makeEngine())

        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        XCTAssertEqual(transport.background.count, 1, "iOS waits for the network itself — the app needn't be running")
        XCTAssertEqual(transport.direct.count, 0, "nothing to send directly with no network")
        XCTAssertNil(try XCTUnwrap(transport.background[safe: 0]).notBefore)
        XCTAssertEqual(engine.displayState(of: try XCTUnwrap(engine.items.first)), .waiting)
    }

    func testOfflineAtTapAlsoGoesDirectlyTheMomentTheNetworkIsBackWithTheAppOpen() async throws {
        network = false
        let engine = await started(makeEngine())
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        network = true
        engine.networkBecameReachable()
        await settle()

        XCTAssertEqual(transport.direct.count, 1, "iOS can sit on its copy after the network returns (#207)")
        XCTAssertEqual(transport.background.count, 1, "iOS already has it — not handed over twice")
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
        let before = transport.direct.count

        engine.sendNow(item.id)
        await settle()

        XCTAssertEqual(transport.direct.count, before + 1, "Send now goes directly at once, whatever the clock")
    }

    // MARK: - Suspended: everything unsent is with iOS
    //
    // M5 on the 2.2 (1) device pass: airplane mode on, send, lock, airplane mode off — nothing went
    // until the app was opened. A suspended app hears no "network back" and runs no timers, so the
    // only thing that can send then is iOS's background transfer, and only if it has the message.
    // These run with the app not in the foreground and no network-back event — the cases the
    // earlier tests (all with the app open, and a hand-fed network-back) couldn't see.

    func testAMessageHandedOverOfflineIsSentByIOSWithNoHelpFromTheApp() async throws {
        network = false
        let engine = await started(makeEngine())
        let item = engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        // Locked; airplane mode off; iOS sends and wakes the app with the result.
        appActive = false
        transport.finish(0, delivered(item.id))
        await settle()

        XCTAssertTrue(engine.items.isEmpty)
        XCTAssertEqual(confirmations.map(\.clientId), [item.id])
    }

    func testW2LeavingTheAppHandsNothingOverEveryMessageAlreadyHasItsCarrier() async throws {
        // Design v2: the server's down; the message's carrier failed and was replaced at once, held
        // by iOS until the clock is due. Leaving the app has nothing to hand over, and nothing to wait
        // for — iOS sends it with the app suspended.
        let engine = await started(makeEngine())
        transport.directResponse = { _ in SendResponse(status: 503) }
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()
        transport.finish(0, status(503))
        await settle()
        XCTAssertEqual(transport.background.count, 2, "replaced at once")
        XCTAssertEqual(try XCTUnwrap(transport.background[safe: 1]).notBefore, now.addingTimeInterval(1),
                       "iOS keeps to the backoff — the server isn't hit again early")
        let directBefore = transport.direct.count

        var done = false
        engine.appWillResignActive { done = true }
        await settle()

        XCTAssertTrue(done, "nothing to keep the app awake for")
        XCTAssertEqual(transport.background.count, 2, "nothing handed over on leaving")
        XCTAssertEqual(transport.direct.count, directBefore, "no direct copy skipping the backoff")
    }
    func testW3LeavingTheAppWaitsForAHandOverStillGettingItsToken() async throws {
        // 2.2 (3) device pass: offline, ten photos were on their way to iOS but still getting a
        // token when the phone locked. Leaving the app didn't wait for them, the app was suspended
        // mid-wait, and iOS never had them — nothing went until the app was opened.
        var release: CheckedContinuation<Void, Never>?
        tokenGate = { await withCheckedContinuation { release = $0 } }
        network = false
        let engine = await started(makeEngine())
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()
        XCTAssertEqual(transport.background.count, 0, "still getting its token")

        var handedOver = false
        engine.appWillResignActive { handedOver = true }
        await settle()
        XCTAssertFalse(handedOver, "the app must stay awake until iOS has it")

        release?.resume()
        await settle()
        XCTAssertEqual(transport.background.count, 1, "with iOS")
        XCTAssertTrue(handedOver)
    }

    func testM9AfterA401WhileSuspendedTheWakeLastsUntilTheMessageIsBackWithIOS() async throws {
        // The token expired while the phone was offline and locked. iOS sends, the server refuses
        // the token, and iOS wakes the app — which it may suspend as soon as the wake is reported
        // handled. Before that the app must refresh the token and hand the message back.
        var release: CheckedContinuation<Void, Never>?
        refreshGate = { await withCheckedContinuation { release = $0 } }
        appActive = false
        let engine = await started(makeEngine())
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        transport.finish(0, status(401))
        var handled = false
        engine.whenHandedOver { handled = true }
        await settle()
        XCTAssertFalse(handled, "still refreshing the token: the wake mustn't end yet")

        release?.resume()
        await settle()
        XCTAssertEqual(transport.background.count, 2, "back with iOS, with a fresh token")
        XCTAssertTrue(handled)
    }

    func testLeavingTheAppWithNothingWaitingReportsDoneAtOnce() async throws {
        let engine = await started(makeEngine())
        var handedOver = false
        engine.appWillResignActive { handedOver = true }
        await settle()
        XCTAssertTrue(handedOver)
        XCTAssertEqual(transport.background.count, 0)
    }

    func testR6AFailedCarrierIsReplacedAtOnceHeldUntilTheClockAppOpenOrNot() async throws {
        // Design v2: the same rule in the foreground and suspended — no hand-back step that only
        // runs in one of them.
        for active in [true, false] {
            transport = FakeTransport()
            transport.directResponse = { _ in SendResponse(status: 503) }
            appActive = true
            now = Date(timeIntervalSince1970: 1_000_000)
            let engine = await started(makeEngine(outbox: Outbox(directory: root.appendingPathComponent("r6-\(active)"))))
            let item = engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
            await settle()

            appActive = active
            transport.finish(0, status(503))   // iOS's copy fails
            await settle()

            XCTAssertEqual(transport.background.count, 2, "active=\(active): not left waiting for the app")
            XCTAssertEqual(try XCTUnwrap(transport.background[safe: 1]).notBefore, now.addingTimeInterval(1))
            transport.finish(1, delivered(item.id))
            await settle()
            XCTAssertTrue(engine.items.isEmpty)
        }
    }
    func testRateLimitedWhileSuspendedGoesBackToIOSAfterRetryAfter() async throws {
        appActive = false
        let engine = await started(makeEngine())
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        transport.finish(0, status(429, retryAfter: "17"))
        await settle()

        XCTAssertEqual(transport.background.count, 2)
        XCTAssertEqual(try XCTUnwrap(transport.background[safe: 1]).notBefore, now.addingTimeInterval(17))
    }

    func testWithNoTokenASuspendedAppWaitsRatherThanRetryingInALoop() async throws {
        // No token means no request to hand iOS; handing back would only fail again at once.
        appActive = false
        tokenResult = .signedOut
        let engine = await started(makeEngine())
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        XCTAssertEqual(tokenCalls, 1)
        XCTAssertEqual(transport.background.count, 0)
        XCTAssertEqual(engine.items.first?.status, .waiting)
    }

    // MARK: - Requirements, as agreed (docs/SEND_REQUIREMENTS.md)
    //
    // Each test is written from its row's wording, not from the code: the ID in the name points at
    // the row. Added after the 2.2 (1) device pass found a row (W3) whose test mirrored the code.

    func testS1EveryKindIsOnDiskBeforeAnythingIsSent() async throws {
        var notOnDisk: [UUID] = []
        transport.onSubmit = { [unowned self] key in
            if Outbox(directory: self.root.appendingPathComponent("Outbox")).item(key.itemId) == nil {
                notOnDisk.append(key.itemId)
            }
        }
        let engine = await started(makeEngine())

        var sent: [UUID] = []
        for kind in [SendItem.Kind.voice, .photo, .video] {
            let file = try engine.files.importData(Data([1, 2, 3]), extension: kind == .voice ? "m4a" : kind == .photo ? "jpg" : "mp4")
            sent.append(engine.enqueueMedia(kind, bookId: book, clubId: club, fileName: file, contentType: "x/y",
                                            durationSeconds: nil, replyTo: nil).id)
        }
        await settle()

        XCTAssertEqual(Set(transport.background.map(\.key.itemId)), Set(sent), "each kind was handed over")
        XCTAssertEqual(notOnDisk, [], "a force-quit at the moment of sending must not lose any kind of message")
    }

    func testO2ATextAfterAVideoGoesImmediatelyWithoutWaitingForTheVideo() async throws {
        let engine = await started(makeEngine())
        let file = try engine.files.importData(Data(repeating: 7, count: 64), extension: "mp4")
        let video = engine.enqueueMedia(.video, bookId: book, clubId: club, fileName: file, contentType: "video/mp4",
                                        durationSeconds: nil, replyTo: nil)
        await settle()
        XCTAssertEqual(transport.background.count, 1, "the video's upload is under way")

        let text = engine.enqueueText(bookId: book, clubId: club, body: "after the video", replyTo: nil)
        await settle()

        XCTAssertEqual(transport.background.count, 2)
        XCTAssertEqual(try XCTUnwrap(transport.background[safe: 1]).key.itemId, text.id, "the text didn't wait for the video")
        XCTAssertEqual(transport.direct.count, 1, "and went directly too, as any text does")
        transport.finish(1, delivered(text.id))
        await settle()
        XCTAssertEqual(engine.items.map(\.id), [video.id], "the text is sent while the video is still uploading")
        XCTAssertLessThan(video.sentAt, text.sentAt, "the video keeps the earlier tap time, so the chat shows it above the text")
    }

    func testR2APassingFailureIsRetriedWithNoLimit() async throws {
        let engine = await started(makeEngine())
        transport.directResponse = { _ in SendResponse(status: 503) }
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        for round in 1...20 {
            transport.finish(transport.background.count - 1, status(503))
            await settle()
            XCTAssertNotEqual(engine.items.first?.status, .refused, "round \(round): never given up on, never red")
            now = now.addingTimeInterval(61)   // past the longest gap
            engine.pump("retry clock")
            await settle()
        }

        XCTAssertEqual(transport.background.count, 21, "twenty failures later it's still being tried")
    }

    func testR4EachGoodNewsTriggerSendsAWaitingMessageAtOnce() async throws {
        let triggers: [(name: String, fire: (SendEngine) -> Void)] = [
            ("network back", { $0.networkBecameReachable() }),
            ("app opened", { $0.appBecameActive() }),
            ("chat opened", { $0.chatOpened() }),
            ("another request succeeded", { $0.serverReachable() }),
            ("Send now", { engine in engine.items.first.map { engine.sendNow($0.id) } }),
        ]
        for trigger in triggers {
            transport = FakeTransport()
            transport.directResponse = { _ in SendResponse(status: 503) }
            let engine = await started(makeEngine(outbox: Outbox(directory: root.appendingPathComponent(trigger.name))))
            engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
            await settle()
            transport.finish(0, status(503))
            await settle()
            XCTAssertEqual(transport.background.count, 2, "\(trigger.name): its carrier replaced, held for the clock")
            let direct = transport.direct.count

            engine.pump("retry clock")   // control: the clock alone says not yet
            await settle()
            XCTAssertEqual(transport.direct.count, direct, "\(trigger.name): the clock sent it early")

            trigger.fire(engine)          // same instant: the trigger alone sends it, directly
            await settle()
            XCTAssertEqual(transport.direct.count, direct + 1, "\(trigger.name) didn't send the waiting message at once")
        }
    }

    func testR4BeingRelaunchedByIOSSendsWaitingMessagesAtOnce() async throws {
        let box = outbox()
        let first = await started(makeEngine(outbox: box))
        transport.directResponse = { _ in SendResponse(status: 503) }
        first.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()
        transport.finish(0, status(503))
        await settle()
        XCTAssertEqual(transport.background.count, 2, "replaced — but that carrier is lost with this run")

        // The app was suspended and terminated; iOS relaunches it in the background (a transfer
        // finished, or it's time for a fetch). A new run, the same outbox on disk.
        transport = FakeTransport()
        appActive = false
        let relaunched = await started(makeEngine(outbox: Outbox(directory: root.appendingPathComponent("Outbox"))))
        await settle()

        XCTAssertEqual(transport.background.count, 1, "a carrier again at once on the wake, not when the app is next opened")
        XCTAssertEqual(relaunched.items.first?.status, .inFlight)
    }

    func testR5WithTheAppOpenTheBackupCheckSendsEvenIfTheNetworkBackEventIsMissed() async throws {
        // Airplane mode off, but the "network back" event never arrives (#203 saw that happen).
        network = false
        let engine = await started(makeEngine())
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()
        XCTAssertEqual(transport.direct.count, 0)

        network = true
        fireWakes(upTo: SendTiming().offlineCheck)
        await settle()

        XCTAssertEqual(transport.direct.count, 1, "within the backup check's minute, not left to iOS's schedule")
    }

    func testT8TheSendLogNamesEveryStepButNeverWhatWasWritten() async throws {
        let secret = "do-not-log-\(UUID().uuidString)"
        let engine = await started(makeEngine())
        transport.directResponse = { _ in SendResponse(status: 503) }
        let sent = engine.enqueueText(bookId: book, clubId: club, body: secret + " sent", replyTo: nil)
        let refused = engine.enqueueText(bookId: book, clubId: club, body: secret + " refused", replyTo: nil)
        await settle()
        transport.finish(0, delivered(sent.id, body: secret + " sent"))
        transport.finish(1, status(400, error: "Not a member of this club."))
        await settle()

        let log = SendLog.recent(limit: 1000)
        XCTAssertFalse(log.contains(secret), "message text must never reach the log (it's attached to Feedback)")
        let short = { (id: UUID) in "[\(id.uuidString.prefix(8))]" }
        for (event, id) in [("queued text", sent.id), ("submit bg", sent.id), ("submit direct", sent.id),
                            ("sent", sent.id), ("refused", refused.id)] {
            XCTAssertTrue(log.contains("\(event) \(short(id))"), "no stable '\(event)' line for the message")
        }
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

        XCTAssertEqual(transport.background.map(\.key.itemId), [lost.id], "no second background copy of what iOS still holds")
        transport.onBackgroundResult?(transport.held[0], delivered(held.id))
        XCTAssertEqual(confirmations.map(\.clientId), [held.id], "the previous run's transfer still confirms it")
        _ = engine
    }

    func testOnRelaunchAMessageIOSStillHoldsAlsoGoesDirectlyWhileTheAppIsOpen() async throws {
        // The app was killed while the server was unreachable; iOS kept the background copy and is
        // retrying it on its own schedule. Reopened, the app must not just wait for iOS.
        let box = outbox()
        var held = SendItem(id: UUID(), bookId: book, clubId: club, kind: .text, sentAt: now, body: "held",
                            status: .inFlight, attempts: 1)
        held.firstFailureAt = now.addingTimeInterval(-60)
        box.add(held)
        transport.held = [SendTaskKey(itemId: held.id, attempt: 1, step: .post)]
        transport.directResponse = { [unowned self] _ in self.delivered(held.id) }

        let engine = await started(makeEngine(outbox: box))
        await settle()

        XCTAssertEqual(transport.direct.count, 1, "sent directly at once, rebuilt from the outbox")
        XCTAssertTrue(engine.items.isEmpty)
        XCTAssertTrue(transport.cancelled.contains(held.id), "iOS's copy is dropped once it's delivered")
        XCTAssertTrue(transport.background.isEmpty, "and no second background copy")
    }

    func testOnRelaunchAMessageIOSWasStillCarryingAlsoGoesDirectly() async throws {
        // Not failing yet — just in flight with iOS when the app was killed. Reopened with the
        // app in front, it goes directly too rather than waiting on iOS's schedule.
        let box = outbox()
        let held = SendItem(id: UUID(), bookId: book, clubId: club, kind: .text, sentAt: now, body: "held",
                            status: .inFlight, attempts: 1)
        box.add(held)
        transport.held = [SendTaskKey(itemId: held.id, attempt: 1, step: .post)]
        transport.directResponse = { [unowned self] _ in self.delivered(held.id) }

        let engine = await started(makeEngine(outbox: box))
        await settle()

        XCTAssertEqual(transport.direct.count, 1)
        XCTAssertTrue(engine.items.isEmpty)
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

    func testV1AVideoIsReservedThenItsCarrierIsOneUploadToTheReservedBlob() async throws {
        let engine = await started(makeEngine())
        let name = try engine.files.importData(Data([7, 7]), extension: "mp4")

        let item = engine.enqueueMedia(.video, bookId: book, clubId: club, fileName: name, contentType: "video/mp4",
                                       durationSeconds: nil, replyTo: nil)
        await settle()

        let reservation = try XCTUnwrap(transport.reservations.first)
        XCTAssertEqual(reservation.request.url?.path, "/books/\(book.uuidString.lowercased())/messages/video")
        XCTAssertEqual(reservation.request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(reservation.body["client_id"] as? String, item.id.uuidString.lowercased())
        XCTAssertNotNil(reservation.body["sent_at"], "tap time: the server creates the message with it")
        XCTAssertEqual(transport.background.count, 1)
        let upload = try XCTUnwrap(transport.background[safe: 0])
        XCTAssertEqual(upload.request.httpMethod, "PUT")
        XCTAssertEqual(upload.request.url?.absoluteString, "https://blob.test/v.mp4?sig=create")
        XCTAssertEqual(upload.request.value(forHTTPHeaderField: "x-ms-blob-type"), "BlockBlob")
        XCTAssertNil(upload.request.value(forHTTPHeaderField: "Authorization"))

        transport.finish(0, SendResponse(status: 201))
        await settle()

        XCTAssertEqual(SendPolicy.unsent(in: engine.items, bookId: book).count, 0, "not unsent: the server creates it now")
        XCTAssertEqual(transport.background.count, 2, "with the app open, its post confirms it")
        let post = json(try XCTUnwrap(transport.background[safe: 1]).request, bodyFile: try XCTUnwrap(transport.background[safe: 1]).bodyFile)
        XCTAssertEqual(post["media_url"] as? String, "https://blob.test/v.mp4")
        XCTAssertEqual(post["type"] as? String, "Video")
        XCTAssertEqual(post["client_id"] as? String, item.id.uuidString.lowercased())
    }

    func testV2AVideoWhoseUploadLandsWhileSuspendedNeedsNothingMoreFromTheApp() async throws {
        let engine = await started(makeEngine())
        let name = try engine.files.importData(Data([7, 7]), extension: "mp4")
        let item = engine.enqueueMedia(.video, bookId: book, clubId: club, fileName: name, contentType: "video/mp4",
                                       durationSeconds: nil, replyTo: nil)
        await settle()

        appActive = false
        transport.finish(0, SendResponse(status: 201))
        await settle()

        XCTAssertEqual(transport.background.count, 1, "no post from the background: the server creates the message")
        XCTAssertEqual(reminders.last, .some(nil), "no 'waiting to send' reminder — it isn't")
        XCTAssertEqual(SendPolicy.unsent(in: engine.items, bookId: book).count, 0)

        appActive = true
        transport.directResponse = { [unowned self] _ in self.delivered(item.id) }
        engine.appBecameActive()
        await settle()
        XCTAssertTrue(engine.items.isEmpty, "confirmed when the app is next open")
    }

    func testV5ReservingASendThatAlreadyGotThroughUploadsNothing() async throws {
        let engine = await started(makeEngine())
        let name = try engine.files.importData(Data([7, 7]), extension: "mp4")
        transport.reserveResponse = { [unowned self] in
            let message = try! JSONSerialization.jsonObject(with: self.delivered(UUID()).body!)
            return SendResponse(status: 200, body: try! JSONSerialization.data(withJSONObject: ["message": message]))
        }
        engine.enqueueMedia(.video, bookId: book, clubId: club, fileName: name, contentType: "video/mp4",
                            durationSeconds: nil, replyTo: nil)
        await settle()

        XCTAssertEqual(transport.background.count, 0, "not uploaded twice")
        XCTAssertTrue(engine.items.isEmpty)
        XCTAssertEqual(confirmations.count, 1)
    }

    func testV6AReservationTheServerRefusesShowsTheReasonAndUploadsNothing() async throws {
        let engine = await started(makeEngine())
        let name = try engine.files.importData(Data([7, 7]), extension: "mp4")
        transport.reserveResponse = { [unowned self] in self.status(400, error: "Not a member of this club.") }
        engine.enqueueMedia(.video, bookId: book, clubId: club, fileName: name, contentType: "video/mp4",
                            durationSeconds: nil, replyTo: nil)
        await settle()

        XCTAssertEqual(engine.displayState(of: try XCTUnwrap(engine.items.first)), .refused("Not a member of this club."))
        XCTAssertEqual(transport.background.count, 0)
    }
    // MARK: - U10: the force-quit reminder follows what's unsent (PR 7)

    func testU10TheReminderIsSetWhenSomethingsUnsentAndMovesAsItSends() async throws {
        let engine = await started(makeEngine())
        let first = engine.enqueueText(bookId: book, clubId: club, body: "1", replyTo: nil)
        await settle()
        XCTAssertEqual(reminders.last, ReminderPlan(fireAt: now.addingTimeInterval(600), count: 1))

        now = now.addingTimeInterval(120)
        let second = engine.enqueueText(bookId: book, clubId: club, body: "2", replyTo: nil)
        await settle()
        XCTAssertEqual(reminders.last??.count, 2)

        transport.finish(0, delivered(first.id))
        await settle()
        XCTAssertEqual(reminders.last, ReminderPlan(fireAt: second.sentAt.addingTimeInterval(600), count: 1),
                       "moves to the oldest still unsent")

        transport.finish(1, delivered(second.id))
        await settle()
        XCTAssertEqual(reminders.last, .some(nil), "cancelled once everything's sent")
    }

    func testU10TheReminderIsOnlyTouchedWhenWhatsUnsentChanges() async throws {
        let engine = await started(makeEngine())
        engine.enqueueText(bookId: book, clubId: club, body: "1", replyTo: nil)
        await settle()
        let set = reminders.count

        engine.pump("retry clock"); engine.chatOpened(); engine.appBecameActive()
        await settle()

        XCTAssertEqual(reminders.count, set, "no churn of notification requests")
    }

    func testU10LeavingTheAppReArmsAReminderThatFellDueWhileItWasOpen() async throws {
        let engine = await started(makeEngine())
        transport.directResponse = { _ in SendResponse(status: 503) }
        engine.enqueueText(bookId: book, clubId: club, body: "1", replyTo: nil)
        await settle()

        now = now.addingTimeInterval(3600)   // overdue, and not shown: the app was open
        engine.appWillResignActive()
        await settle()

        XCTAssertEqual(reminders.last??.fireAt, now.addingTimeInterval(60))
    }

    // MARK: - U16: messages from the share sheet (PR 10)

    func testU16AShareSheetMessageIOSHasIsWaitedForAndItsResultConfirmsIt() async throws {
        let inbox = root.appendingPathComponent("inbox")
        var shared = try ShareInbox.add(.init(id: UUID(), bookId: book, clubId: club, kind: .photo, sentAt: now),
                                        photo: Data([0xFF, 0xD8]), in: inbox)
        shared.sessionIdentifier = ShareInbox.newSessionIdentifier()
        try ShareInbox.save(shared, in: inbox)
        let engine = makeEngine()
        engine.shareInbox = inbox
        transport.held = [SendTaskKey(itemId: shared.id, attempt: 1, step: .post)]
        _ = await started(engine)
        await settle()

        XCTAssertEqual(engine.items.map(\.id), [shared.id], "it's an unsent message in the app now")
        XCTAssertEqual(engine.items.first?.status, .inFlight)
        XCTAssertEqual(transport.background.count, 0, "iOS has it — not sent a second time")
        XCTAssertTrue(ShareInbox.entries(in: inbox).isEmpty, "taken out of the inbox")

        transport.onBackgroundResult?(SendTaskKey(itemId: shared.id, attempt: 1, step: .post), delivered(shared.id))
        await settle()
        XCTAssertTrue(engine.items.isEmpty)
        XCTAssertEqual(confirmations.map(\.clientId), [shared.id])
    }

    func testU16AShareSheetUploadInASessionNotYetJoinedIsWaitedForNotUploadedAgain() async throws {
        // The app joins a share's session only when iOS wakes it with the results — one process at
        // a time can hold a session, and the extension may still have it. Until then the message is
        // with iOS: no second background upload (with the app open it also goes directly; dedup).
        let inbox = root.appendingPathComponent("inbox")
        var shared = try ShareInbox.add(.init(id: UUID(), bookId: book, clubId: club, kind: .text, sentAt: now,
                                              body: "shared"), photo: nil, in: inbox)
        shared.sessionIdentifier = ShareInbox.newSessionIdentifier()
        try ShareInbox.save(shared, in: inbox)
        let engine = makeEngine()
        engine.shareInbox = inbox
        _ = await started(engine)   // transport.held is empty: this run can't see that session
        await settle()

        XCTAssertEqual(engine.items.first?.status, .inFlight, "still with iOS, not started again")
        XCTAssertEqual(transport.background.count, 0)
        XCTAssertEqual(transport.direct.count, 1, "and sent directly too, with the app open")
    }

    func testU16AShareSheetMessageNotHandedToIOSIsSentByTheApp() async throws {
        // The sheet had no token to hand it over with (offline and it needed refreshing).
        let inbox = root.appendingPathComponent("inbox")
        let shared = try ShareInbox.add(.init(id: UUID(), bookId: book, clubId: club, kind: .text, sentAt: now,
                                              body: "from the share sheet"), photo: nil, in: inbox)
        let engine = makeEngine()
        engine.shareInbox = inbox
        _ = await started(engine)
        await settle()

        XCTAssertEqual(try XCTUnwrap(transport.background[safe: 0]).key.itemId, shared.id)
    }

    func testU16TakingTheInboxTwiceDoesntDuplicate() async throws {
        let inbox = root.appendingPathComponent("inbox")
        let shared = ShareInbox.Entry(id: UUID(), bookId: book, clubId: club, kind: .text, sentAt: now, body: "once")
        try ShareInbox.add(shared, photo: nil, in: inbox)
        let engine = makeEngine()
        engine.shareInbox = inbox
        _ = await started(engine)
        try ShareInbox.add(shared, photo: nil, in: inbox)   // written again before the record went
        engine.appBecameActive()
        await settle()

        XCTAssertEqual(engine.items.filter { $0.id == shared.id }.count, 1)
    }

    // MARK: - U9: video compressed after it's queued (PR 5)

    private func queueVideo(_ engine: SendEngine, bytes: Int = 4096) throws -> SendItem {
        let name = try engine.files.importData(Data(repeating: 9, count: bytes), extension: "mp4")
        return engine.enqueueMedia(.video, bookId: book, clubId: club, fileName: name, contentType: "video/mp4",
                                   durationSeconds: nil, replyTo: nil, compress: true)
    }

    func testU9AVideoIsQueuedAtOnceAndCompressedBeforeItsUpload() async throws {
        var release: CheckedContinuation<Void, Never>?
        compressGate = { await withCheckedContinuation { release = $0 } }
        let engine = await started(makeEngine())

        let item = try queueVideo(engine)
        await settle()
        XCTAssertEqual(engine.items.map(\.id), [item.id], "queued — and the bubble shown — before compressing")
        XCTAssertEqual(compressed.count, 1, "compressing")
        XCTAssertEqual(transport.background.count, 0, "nothing uploads until it's compressed")

        release?.resume()
        await settle()
        let upload = try XCTUnwrap(transport.background[safe: 0])
        XCTAssertEqual(upload.request.httpMethod, "PUT")
        XCTAssertEqual(try Data(contentsOf: upload.bodyFile), Data([1]), "the compressed copy is what's uploaded")
        let saved = try XCTUnwrap(engine.items.first)
        XCTAssertNotEqual(saved.fileName, item.fileName)
        XCTAssertTrue(engine.files.fileExists(try XCTUnwrap(item.fileName)), "the original is kept until it's sent")
    }

    func testU9WhenItCantBeCompressedTheOriginalIsSent() async throws {
        compression = { _ in .unsupported }
        let engine = await started(makeEngine())
        let item = try queueVideo(engine, bytes: 64)
        await settle()

        let upload = try XCTUnwrap(transport.background[safe: 0])
        XCTAssertEqual(upload.bodyFile, engine.files.fileURL(try XCTUnwrap(item.fileName)))
    }

    func testU9TooLargeEvenAfterCompressingIsRefusedWithTheReason() async throws {
        compression = { _ in
            let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try? FileHandle(forWritingTo: out)
            try? handle?.truncate(atOffset: UInt64(SendItem.maxVideoBytes) + 1)   // sparse: no real 100 MB
            try? handle?.close()
            return .compressed(out)
        }
        let engine = await started(makeEngine())
        let item = try queueVideo(engine)
        await settle()

        XCTAssertEqual(engine.displayState(of: try XCTUnwrap(engine.items.first)), .refused("Video is too large (max 100 MB)."))
        XCTAssertEqual(transport.reservations.count, 0, "nothing reserved or uploaded")
        XCTAssertEqual(engine.items.first?.id, item.id)
    }

    func testU9AnInterruptedCompressionStartsAgainFromTheOriginal() async throws {
        compression = { _ in .interrupted }
        let engine = await started(makeEngine())
        let item = try queueVideo(engine)
        await settle()
        XCTAssertEqual(engine.items.first?.status, .waiting, "waiting to start again, not failed")
        XCTAssertNotEqual(engine.displayState(of: try XCTUnwrap(engine.items.first)), .refused(""))
        XCTAssertEqual(transport.reservations.count, 0)

        compression = { source in
            let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            try? Data([1]).write(to: out)
            return .compressed(out)
        }
        engine.appBecameActive()
        await settle()
        XCTAssertEqual(compressed, Array(repeating: engine.files.fileURL(try XCTUnwrap(item.fileName)), count: 2))
        XCTAssertEqual(transport.background.count, 1, "compressed this time, and uploading")
    }

    func testU9AVideoStillCompressingWhenTheAppEndedIsCompressedAgainOnRelaunch() async throws {
        compressGate = { await withCheckedContinuation { _ in } }   // never finishes: the app ends
        let first = await started(makeEngine())
        let item = try queueVideo(first)
        await settle()
        compressGate = nil

        let relaunched = await started(makeEngine(outbox: Outbox(directory: root.appendingPathComponent("Outbox"))))
        await settle()

        XCTAssertEqual(compressed.last, relaunched.files.fileURL(try XCTUnwrap(item.fileName)))
        XCTAssertEqual(transport.background.count, 1)
    }

    func testU9OfflineAVideoIsCompressedThenWaitsWithoutAReservation() async throws {
        network = false
        let engine = await started(makeEngine())
        _ = try queueVideo(engine)
        await settle()

        XCTAssertEqual(compressed.count, 1, "compressing needs no network")
        XCTAssertEqual(transport.reservations.count, 0, "a reservation needs one: no carrier yet")
        XCTAssertEqual(engine.items.first?.status, .waiting)

        appActive = false   // locked, still offline
        engine.pump("retry clock")
        await settle()
        XCTAssertEqual(transport.background.count, 0, "nothing to hand iOS without a reservation")
        XCTAssertEqual(compressed.count, 1, "and not compressed again")
    }
    func testU9AFailedUploadIsReplacedAtOnceWithAFreshReservationNotCompressedAgain() async throws {
        let engine = await started(makeEngine())
        _ = try queueVideo(engine)
        await settle()
        transport.finish(0, SendResponse(status: 503))
        await settle()

        XCTAssertEqual(transport.reservations.count, 2, "a fresh link for the new carrier")
        XCTAssertEqual(transport.background.count, 2)
        XCTAssertEqual(try XCTUnwrap(transport.background[safe: 1]).notBefore, now.addingTimeInterval(1), "held until the clock")
        XCTAssertEqual(compressed.count, 1, "compressed once, not again on a retry")
    }

    func testV7AnUploadStorageRefusesIsReservedAgainNotShownAsRefused() async throws {
        // A week-old link, or a repeat of an upload that already landed (the link is create-only):
        // the reservation then says it's sent, or gives a fresh link.
        let engine = await started(makeEngine())
        _ = try queueVideo(engine)
        await settle()
        transport.finish(0, SendResponse(status: 403))
        await settle()

        XCTAssertNotEqual(engine.items.first?.status, .refused)
        XCTAssertEqual(transport.reservations.count, 2, "reserved again")
    }

    // MARK: - Continued processing for a video (design v2)

    func testCPAVideoAsksIOSToKeepItsWorkGoingAtTheTapAndReleasesItOnceUploaded() async throws {
        let engine = await started(makeEngine())
        let item = try queueVideo(engine)
        await settle()

        XCTAssertEqual(videoWork.first, .start(item.id), "asked for at the tap, with the app in front")
        XCTAssertTrue(videoWork.contains(.progress(item.id, 0.35)), "compressing reports progress")
        XCTAssertTrue(videoWork.contains(.progress(item.id, 0.75)), "reserved")
        XCTAssertFalse(videoWork.contains { if case .finish = $0 { return true }; return false }, "still uploading")

        transport.onBackgroundProgress?(try XCTUnwrap(transport.background.first).key, 50, 100)
        XCTAssertEqual(videoWork.last, .progress(item.id, 0.875), "the upload is the last quarter")

        transport.finish(0, SendResponse(status: 201))
        await settle()
        XCTAssertEqual(videoWork.last, .finish(item.id, success: true))
    }

    func testCPWhenIOSEndsItTheCompressionStopsAndStartsAgainOnlyWithTheAppOpen() async throws {
        var release: CheckedContinuation<Void, Never>?
        compressGate = { await withCheckedContinuation { release = $0 } }
        compression = { _ in Task.isCancelled ? .interrupted : .unsupported }   // like the real export
        let engine = await started(makeEngine())
        let item = try queueVideo(engine)
        await settle()
        XCTAssertEqual(compressed.count, 1)

        appActive = false
        engine.videoWorkEnded(item.id)   // expired, or cancelled by the user
        release?.resume()
        await settle()
        XCTAssertEqual(engine.items.first?.status, .waiting)

        compressGate = nil
        compression = { _ in .unsupported }
        engine.pump("retry clock")
        await settle()
        XCTAssertEqual(compressed.count, 1, "not restarted with the app suspended and nothing keeping it going")

        appActive = true
        engine.appBecameActive()
        await settle()
        XCTAssertEqual(compressed.count, 2, "started again with the app open")
        XCTAssertEqual(transport.background.count, 1)
    }

    func testCPLeavingTheAppOrAWakeDoesntWaitForAVideoStillCompressing() async throws {
        compressGate = { await withCheckedContinuation { _ in } }   // a long video
        let engine = await started(makeEngine())
        _ = try queueVideo(engine)
        await settle()

        var done = false
        engine.appWillResignActive { done = true }
        await settle()
        XCTAssertTrue(done, "compressing can outlast iOS's ~30 s and a wake: continued processing (or the next run) has it")
    }

    func testCPNotAskedForAMessageThatIsntAVideo() async throws {
        let engine = await started(makeEngine())
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()
        XCTAssertEqual(videoWork, [])
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
