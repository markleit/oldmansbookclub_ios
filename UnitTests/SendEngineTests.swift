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
        var background: [(key: SendTaskKey, request: URLRequest, bodyFile: URL, notBefore: Date?)] = []
        var direct: [URLRequest] = []
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
    private var tokenResult: APIClient.SendToken = .token("tok")
    /// When set, getting a token waits here (a refresh that takes a while).
    private var tokenGate: (() async -> Void)?
    private var uploadLinkCalls = 0
    /// Videos handed to the compressor, and what it does: by default a smaller copy.
    private var compressed: [URL] = []
    private var compressGate: (() async -> Void)?
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
            token: { [unowned self] validFor in
                self.tokenCalls.append(validFor)
                if let gate = self.tokenGate { await gate() }
                return self.tokenResult
            },
            tokenAfterRejection: { [unowned self] in
                self.rejections += 1
                if let gate = self.refreshGate { await gate() }
                return self.tokenAfterRejectionResult
            },
            uploadLink: { [unowned self] _, _ in
                self.uploadLinkCalls += 1
                return (URL(string: "https://blob.test/v.mp4?sig=w")!, "https://blob.test/v.mp4")
            },
            compressVideo: { [unowned self] source in
                self.compressed.append(source)
                if let gate = self.compressGate { await gate() }
                return self.compression(source)
            },
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
        let before = transport.background.count

        engine.sendNow(item.id)
        await settle()

        XCTAssertEqual(transport.background.count, before + 1)
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

    func testLeavingTheAppHandsIOSWhatsWaitingOnTheClock() async throws {
        // The server's down: the message fails and waits on the retry clock — which stops when the
        // app is suspended, so it has to go to iOS as the app leaves.
        let engine = await started(makeEngine())
        transport.directResponse = { _ in SendResponse(status: 503) }
        engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()
        transport.finish(0, status(503))
        await settle()
        XCTAssertEqual(engine.items.first?.status, .waiting)
        let directBefore = transport.direct.count

        var handedOver = false
        engine.appWillResignActive { handedOver = true }
        await settle()

        XCTAssertTrue(handedOver, "the app is kept awake until this reports done")
        XCTAssertEqual(transport.background.count, 2)
        XCTAssertEqual(try XCTUnwrap(transport.background[safe: 1]).notBefore, now.addingTimeInterval(1),
                       "iOS keeps to the backoff — the server isn't hit again early")
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

    func testAFailureWhileSuspendedGoesStraightBackToIOSOnTheBackoff() async throws {
        let engine = await started(makeEngine())
        transport.directResponse = { _ in SendResponse(status: 503) }
        let item = engine.enqueueText(bookId: book, clubId: club, body: "hello", replyTo: nil)
        await settle()

        appActive = false
        transport.finish(0, status(503))   // iOS's copy fails while the app is suspended
        await settle()

        XCTAssertEqual(transport.background.count, 2, "not left waiting for the app to be opened")
        XCTAssertEqual(try XCTUnwrap(transport.background[safe: 1]).notBefore, now.addingTimeInterval(1))
        transport.finish(1, delivered(item.id))
        await settle()
        XCTAssertTrue(engine.items.isEmpty)
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

        XCTAssertEqual(tokenCalls.count, 1)
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
            XCTAssertEqual(engine.items.first?.status, .waiting, "round \(round): never given up on, never red")
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
            XCTAssertEqual(engine.items.first?.status, .waiting, trigger.name)

            engine.pump("retry clock")   // control: the clock alone says not yet
            await settle()
            XCTAssertEqual(transport.background.count, 1, "\(trigger.name): the clock sent it early")

            trigger.fire(engine)          // same instant: the trigger alone sends it
            await settle()
            XCTAssertEqual(transport.background.count, 2, "\(trigger.name) didn't send the waiting message at once")
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
        XCTAssertEqual(first.items.first?.status, .waiting)

        // The app was suspended and terminated; iOS relaunches it in the background (a transfer
        // finished, or it's time for a fetch). A new run, the same outbox on disk.
        transport = FakeTransport()
        appActive = false
        let relaunched = await started(makeEngine(outbox: Outbox(directory: root.appendingPathComponent("Outbox"))))
        await settle()

        XCTAssertEqual(transport.background.count, 1, "sent at once on the wake, not when the app is next opened")
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
        XCTAssertEqual(uploadLinkCalls, 0, "nothing uploaded")
        XCTAssertEqual(engine.items.first?.id, item.id)
    }

    func testU9AnInterruptedCompressionStartsAgainFromTheOriginal() async throws {
        compression = { _ in .interrupted }
        let engine = await started(makeEngine())
        let item = try queueVideo(engine)
        await settle()
        XCTAssertEqual(engine.items.first?.status, .queued, "waiting to start again, not failed")
        XCTAssertEqual(uploadLinkCalls, 0)

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

    func testU9OfflineAVideoIsCompressedThenWaitsWithoutAskingForAnUploadLink() async throws {
        network = false
        appActive = false
        let engine = await started(makeEngine())
        _ = try queueVideo(engine)
        await settle()

        XCTAssertEqual(compressed.count, 1, "compressing needs no network")
        XCTAssertEqual(uploadLinkCalls, 0, "an upload link needs one: don't wait for it inside the hand-over")
        XCTAssertEqual(engine.items.first?.status, .waiting)
        XCTAssertEqual(transport.background.count, 0, "and no hand-back loop while suspended")
    }

    func testU9AFailedUploadGetsAFreshLink() async throws {
        let engine = await started(makeEngine())
        _ = try queueVideo(engine)
        await settle()
        transport.finish(0, SendResponse(status: 503))
        await settle()
        now = now.addingTimeInterval(1)
        engine.pump("retry clock")
        await settle()

        XCTAssertEqual(uploadLinkCalls, 2, "an upload link can expire: each try asks for a new one")
        XCTAssertEqual(compressed.count, 1, "compressed once, not again on a retry")
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
