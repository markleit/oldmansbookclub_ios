import Combine
import Foundation

// #204 — sends every message the user taps Send on, as soon as possible, whatever happens next.
//
// App-level, started at launch (also when iOS launches the app in the background to report a
// transfer), and never tied to a screen: the chat only draws `items` and listens for
// `confirmations`. This replaces the send machinery that lived in BookViewModel — a per-chat queue,
// two watchdogs, several retry passes and their guards — which stopped the moment you left the chat.
//
// Each message: saved to the Outbox → handed to iOS's background transfer at tap time (and sent
// directly too when that's faster) → delivered, or retried on ONE shared clock (1, 2, 4, 8, 15,
// 30 s, then every 60 s, no limit) for anything that can pass, or refused with the server's reason.
// The rules are SendPolicy's; this class applies them.

/// A message the server confirmed, for whichever chat is showing it.
struct SendConfirmation {
    let bookId: UUID
    let clientId: UUID
    let message: Message
}

/// Everything the engine needs from the outside world, injectable so it's unit-tested with fakes
/// (#204 T1).
struct SendEnvironment {
    var now: () -> Date = { Date() }
    /// In [-1, 1] — scaled by SendTiming.jitter.
    var jitter: () -> Double = { Double.random(in: -1...1) }
    var isAppActive: () -> Bool
    var hasNetwork: () -> Bool
    var baseURL: () -> URL
    var deviceId: () -> String?
    var myUserId: () -> UUID?
    /// Tokens: `validFor` refreshes first if the stored one expires sooner; `afterRejecting`
    /// refreshes after a 401.
    var token: (_ validFor: TimeInterval) async -> APIClient.SendToken
    var tokenAfterRejection: () async -> APIClient.SendToken
    /// A video's blob upload link: (SAS upload URL, the blob's plain URL).
    var uploadLink: (_ clubId: UUID, _ ext: String) async throws -> (URL, String)
    /// Run `action` after `delay` seconds; returns a cancel function.
    var schedule: (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void
    /// Keep the saved chat in step when a message is confirmed with no chat open (A2).
    var cacheConfirmed: (_ bookId: UUID, _ message: Message) -> Void
}

@MainActor
final class SendEngine: ObservableObject {
    /// Every unsent message, oldest tap first — what pending bubbles and Library counts draw.
    @Published private(set) var items: [SendItem] = []
    /// No network path at all (airplane mode, no signal).
    @Published private(set) var isOffline = false
    /// A message the server now has — from either transfer route, or another channel via `confirm`.
    let confirmations = PassthroughSubject<SendConfirmation, Never>()

    let timing: SendTiming
    private let outbox: Outbox
    private let transport: SendTransport
    private let env: SendEnvironment

    private var clock = RetryClock()
    /// Requests for an item currently out (background + direct copies of its latest attempt).
    private var copies: [UUID: Int] = [:]
    /// The latest post request per in-flight item, so it can also go direct (nudge, network back).
    private var builtPosts: [UUID: (SendTaskKey, SendRequestBuilder.Built)] = [:]
    private var directInFlight: Set<UUID> = []
    private var refreshedAfter401: Set<UUID> = []
    /// Book of each message the user deleted while it was unsent — a late success for one (D1)
    /// still needs to reach its chat. (A message already confirmed isn't here: its other copy's
    /// late success is just a duplicate.)
    private var deletedBooks: [UUID: UUID] = [:]
    private var cancelWake: (() -> Void)?
    private var started = false

    init(outbox: Outbox, transport: SendTransport, environment: SendEnvironment, timing: SendTiming = .current) {
        self.outbox = outbox
        self.transport = transport
        self.env = environment
        self.timing = timing
    }

    // MARK: - Lifecycle

    /// Once per launch, before anything else touches the transport: takes over 2.1's queues,
    /// re-attaches to transfers iOS still holds, and sends whatever's ready.
    func start() async {
        guard !started else { return }
        started = true
        transport.onBackgroundResult = { [weak self] key, response in
            self?.handle(key, response, direct: false)
        }
        let taken = outbox.migrateLegacy()
        if taken > 0 { SendLog.note("migrated legacy", nil, "items=\(taken)") }
        isOffline = !env.hasNetwork()

        // Anything marked in flight by the last run: if iOS still holds a transfer for it, wait for
        // that; otherwise (the run ended before it went) it's ready again.
        let held = await transport.backgroundTaskKeys()
        for item in outbox.items where item.status == .inFlight {
            let count = held.filter { $0.itemId == item.id }.count
            if count > 0 {
                copies[item.id] = count
                // iOS still has it, but on its own schedule — with the app open, also send it
                // directly (rebuilt: the request from the previous run died with it). Without this
                // a message stranded by an outage just before the app was killed waited on iOS
                // alone after relaunch (found by HermeticSendUITests' kill test on CI).
                sendDirectIfPossible(item.id)
            } else {
                outbox.update(item.id) { $0.status = .queued }
            }
        }
        publish()
        pump("launch")
    }

    // MARK: - Sending (the chat calls these)

    @discardableResult
    func enqueueText(bookId: UUID, clubId: UUID, body: String, replyTo: Message?) -> SendItem {
        enqueue(SendItem(id: UUID(), bookId: bookId, clubId: clubId, kind: .text,
                         sentAt: outbox.nextSentAt(now: env.now()), body: body,
                         parentMessageId: replyTo?.id, parentSenderName: replyTo?.senderName,
                         parentPreview: replyTo.map(Self.preview)))
    }

    /// `fileName` is already in the outbox (Outbox.importFile / importData).
    @discardableResult
    func enqueueMedia(_ kind: SendItem.Kind, bookId: UUID, clubId: UUID, fileName: String, contentType: String,
                      durationSeconds: Int?, replyTo: Message?) -> SendItem {
        enqueue(SendItem(id: UUID(), bookId: bookId, clubId: clubId, kind: kind,
                         sentAt: outbox.nextSentAt(now: env.now()), fileName: fileName, contentType: contentType,
                         durationSeconds: durationSeconds, parentMessageId: replyTo?.id,
                         parentSenderName: replyTo?.senderName, parentPreview: replyTo.map(Self.preview)))
    }

    @discardableResult
    func enqueueForward(bookId: UUID, clubId: UUID, messageId: UUID) -> SendItem {
        enqueue(SendItem(id: UUID(), bookId: bookId, clubId: clubId, kind: .forward,
                         sentAt: outbox.nextSentAt(now: env.now()), forwardMessageId: messageId))
    }

    /// The outbox the chat imports media files into.
    var files: Outbox { outbox }

    private func enqueue(_ item: SendItem) -> SendItem {
        outbox.add(item)   // on disk before anything goes over the network
        SendLog.note("queued \(item.kind.rawValue)", item.id)
        // A new send is the user asking for it now — it doesn't wait out an old backoff.
        clock.reset()
        publish()
        pump("send")
        return item
    }

    /// "Send now" on a waiting message.
    func sendNow(_ id: UUID) {
        guard let item = outbox.item(id), item.status != .refused else { return }
        SendLog.note("send now", id)
        outbox.update(id) { $0.firstFailureAt = nil }
        clock.reset()
        if item.status == .inFlight {
            sendDirectIfPossible(id)
        } else {
            pump("send now")
        }
    }

    /// Delete an unsent message (waiting or refused). If it reaches the server anyway — a transfer
    /// was already on its way — it's shown as sent: it exists, and normal delete removes it (D1).
    func delete(_ id: UUID) {
        guard let item = outbox.item(id) else { return }
        SendLog.note("deleted", id)
        transport.cancelBackground(itemId: id)
        deletedBooks[id] = item.bookId
        forget(item, fileGrace: 0)
        publish()
    }

    // MARK: - Triggers

    func networkBecameReachable() {
        SendLog.note("network back")
        isOffline = false
        clock.reset()
        // iOS can sit on a background transfer for a while after the network returns (#207):
        // anything already handed over also goes directly now.
        for item in outbox.items where item.status == .inFlight { sendDirectIfPossible(item.id) }
        pump("network back")
    }

    func networkLost() {
        isOffline = true
        publish()
    }

    func appBecameActive() {
        clock.reset()
        pump("foreground")
    }

    func chatOpened() {
        clock.reset()
        pump("chat open")
    }

    /// Any API request succeeded: the server's reachable, so nothing should be waiting on the clock.
    func serverReachable() {
        guard clock.isBackingOff else { return }
        clock.reset()
        pump("server reachable")
    }

    /// Another channel showed the server has it — the SignalR echo, or a chat reload.
    func confirm(clientId: UUID, message: Message) {
        guard let item = outbox.item(clientId) else { return }
        delivered(item, message, via: "echo")
    }

    /// A 2.1 background upload (started before the update) finished: its blob is up, so this
    /// message only needs posting — not uploading again. One-time bridge; see BackgroundUploadService.
    func legacyBlobUploaded(_ id: UUID, mediaUrl: String) {
        guard let item = outbox.item(id), item.mediaUrl == nil else { return }
        SendLog.note("legacy upload finished", id)
        outbox.update(id) { $0.mediaUrl = mediaUrl }
    }

    // MARK: - Deciding what to send

    func pump(_ reason: String) {
        let now = env.now()
        clock.clearRateLimit(now: now)
        if !env.hasNetwork() {
            isOffline = true
            for item in outbox.items where item.status == .queued {
                markWaiting(item.id, because: "offline", now: now)
            }
        } else {
            isOffline = false
            let ids = SendPolicy.itemsToSubmit(outbox.items, clock: clock, now: now, isOffline: false)
            if !ids.isEmpty { SendLog.note("pump", nil, "reason=\(reason) items=\(ids.count)") }
            for id in ids { submit(id) }
            // In flight with iOS but already failing directly: retry directly on the same clock.
            if clock.isDue(now: now) {
                for item in outbox.items where item.status == .inFlight && item.firstFailureAt != nil {
                    sendDirectIfPossible(item.id)
                }
            }
        }
        scheduleWake()
        publish()
    }

    private func submit(_ id: UUID) {
        guard let item = outbox.item(id), item.status == .queued || item.status == .waiting else { return }
        let attempt = item.attempts + 1
        outbox.update(id) { $0.status = .inFlight; $0.attempts = attempt }
        copies[id] = 0
        Task { await send(id, attempt: attempt) }
    }

    private func send(_ id: UUID, attempt: Int) async {
        let token: String
        switch await env.token(timing.tokenFreshness) {
        case .token(let t): token = t
        case .signedOut: return fail(id, attempt: attempt, .transient("signed out"))
        case .unavailable: return fail(id, attempt: attempt, .transient("token refresh unavailable"))
        }
        guard let item = outbox.item(id), item.attempts == attempt else { return }
        if item.kind == .video && item.mediaUrl == nil {
            await uploadVideo(item, attempt: attempt)
        } else {
            post(item, attempt: attempt, token: token)
        }
    }

    private func post(_ item: SendItem, attempt: Int, token: String) {
        let fileURL = item.fileName.map(outbox.fileURL)
        if item.mediaUrl == nil, let fileName = item.fileName, !outbox.fileExists(fileName) {
            return refuse(item.id, "This message's file is missing from your phone, so it can't be sent.")   // D4
        }
        let built = SendRequestBuilder.post(item, baseURL: env.baseURL(), token: token,
                                            deviceId: env.deviceId(), fileURL: fileURL)
        let key = SendTaskKey(itemId: item.id, attempt: attempt, step: .post)
        let bodyFile: URL
        if let file = built.bodyFile {
            bodyFile = file
        } else {
            do { bodyFile = try outbox.writeRequestBody(built.jsonBody ?? Data(), for: item.id, attempt: attempt) }
            catch { return fail(item.id, attempt: attempt, .transient("couldn't write the request")) }
        }
        builtPosts[item.id] = (key, built)
        transport.submitBackground(key, request: built.request, bodyFile: bodyFile)
        copies[item.id, default: 0] += 1
        SendLog.note("submit bg", item.id, "attempt=\(attempt) kind=\(item.kind.rawValue)")

        guard env.isAppActive() else { return }
        if built.bodyFile == nil {
            // Small JSON: also straight away, directly — never slower than before this engine.
            sendDirectIfPossible(item.id)
        } else {
            // A media file: give iOS's copy a few seconds before uploading it a second time.
            _ = env.schedule(timing.directNudge) { [weak self] in
                guard let self, let current = self.outbox.item(item.id),
                      current.status == .inFlight, current.attempts == attempt else { return }
                self.sendDirectIfPossible(item.id)
            }
        }
    }

    private func sendDirectIfPossible(_ id: UUID) {
        guard env.isAppActive(), env.hasNetwork(), !directInFlight.contains(id) else { return }
        if let (key, built) = builtPosts[id] { return sendDirect(id, key, built) }

        // No request in hand: after a relaunch iOS can still hold a message's background copy while
        // this run holds nothing. Rebuild the post (same attempt) so it can go directly too. A
        // video whose blob isn't up yet is left to iOS — re-uploading it directly isn't worth it.
        guard let item = outbox.item(id), item.status == .inFlight,
              !(item.kind == .video && item.mediaUrl == nil) else { return }
        directInFlight.insert(id)
        Task {
            defer { directInFlight.remove(id) }
            guard case .token(let token) = await env.token(timing.tokenFreshness),
                  let current = outbox.item(id), current.status == .inFlight else { return }
            if current.mediaUrl == nil, let name = current.fileName, !outbox.fileExists(name) { return }
            let built = SendRequestBuilder.post(current, baseURL: env.baseURL(), token: token,
                                                deviceId: env.deviceId(),
                                                fileURL: current.fileName.map(outbox.fileURL))
            let key = SendTaskKey(itemId: id, attempt: current.attempts, step: .post)
            builtPosts[id] = (key, built)
            directInFlight.remove(id)
            sendDirect(id, key, built)
        }
    }

    private func sendDirect(_ id: UUID, _ key: SendTaskKey, _ built: SendRequestBuilder.Built) {
        guard !directInFlight.contains(id) else { return }
        directInFlight.insert(id)
        copies[id, default: 0] += 1
        SendLog.note("submit direct", id, "attempt=\(key.attempt)")
        Task {
            let response = await transport.sendDirect(built.request, body: built.jsonBody, bodyFile: built.bodyFile)
            directInFlight.remove(id)
            handle(key, response, direct: true)
        }
    }

    private func uploadVideo(_ item: SendItem, attempt: Int) async {
        guard let fileName = item.fileName, outbox.fileExists(fileName) else {
            return refuse(item.id, "This message's file is missing from your phone, so it can't be sent.")
        }
        let link: (URL, String)
        do {
            link = try await env.uploadLink(item.clubId, "mp4")
        } catch {
            let response: SendResponse
            if case APIError.serverError(let status) = error {
                response = SendResponse(status: status)
            } else {
                response = SendResponse(error: error)
            }
            return fail(item.id, attempt: attempt, response.verdict)
        }
        let built = SendRequestBuilder.blobUpload(uploadUrl: link.0, fileURL: outbox.fileURL(fileName),
                                                  contentType: item.contentType ?? "video/mp4")
        let key = SendTaskKey(itemId: item.id, attempt: attempt, step: .blobUpload(mediaUrl: link.1))
        transport.submitBackground(key, request: built.request, bodyFile: outbox.fileURL(fileName))
        copies[item.id, default: 0] += 1
        SendLog.note("submit bg", item.id, "attempt=\(attempt) step=blob")
    }

    // MARK: - Results

    private func handle(_ key: SendTaskKey, _ response: SendResponse, direct: Bool) {
        let id = key.itemId
        if let remaining = copies[id] { copies[id] = max(0, remaining - 1) }
        // The losing copy of a send we already finished, cancelled on purpose.
        if (response.error as? URLError)?.code == .cancelled { return }
        let verdict = response.verdict
        let via = direct ? "direct" : "bg"

        guard let item = outbox.item(id) else {
            // Already confirmed by the other copy — or deleted while on its way (D1): a success is
            // still a real message, so its chat hears about it.
            if verdict == .delivered, key.step == .post, let book = deletedBooks.removeValue(forKey: id),
               let message = Self.decode(response.body) {
                SendLog.note("sent after delete", id, "via=\(via)")
                env.cacheConfirmed(book, message)
                confirmations.send(SendConfirmation(bookId: book, clientId: id, message: message))
            }
            return
        }

        switch (key.step, verdict) {
        case (.post, .delivered):
            guard let message = Self.decode(response.body) else {
                return fail(id, attempt: key.attempt, .transient("unreadable response"), direct: direct)
            }
            delivered(item, message, via: via)

        case (.blobUpload(let mediaUrl), .delivered):
            SendLog.note("blob uploaded", id)
            outbox.update(id) { $0.mediaUrl = mediaUrl; $0.status = .queued }
            submit(id)

        default:
            fail(id, attempt: key.attempt, verdict, direct: direct)
        }
    }

    private func fail(_ id: UUID, attempt: Int, _ verdict: SendVerdict, direct: Bool = false) {
        guard let item = outbox.item(id) else { return }
        // A newer attempt is already out: an older one failing changes nothing.
        guard item.attempts == attempt else { return }
        let now = env.now()

        switch verdict {
        case .delivered:
            return
        case .refused(let reason):
            refuse(id, reason)
        case .refreshAuth where !refreshedAfter401.contains(id):
            refreshedAfter401.insert(id)
            SendLog.note("token refused, refreshing", id)
            Task {
                let result = await env.tokenAfterRejection()
                // While the token was being refreshed the message may have moved on — the retry
                // clock already sent a newer attempt, or it was delivered or deleted. Resubmitting
                // regardless sent a second, overlapping attempt (found by a flaky CI run: one
                // attempt hit a refusal, the other got through).
                guard let current = outbox.item(id), current.attempts == attempt,
                      current.status != .refused else { return }
                switch result {
                case .token:
                    transport.cancelBackground(itemId: id)
                    outbox.update(id) { $0.status = .queued }
                    submit(id)
                case .signedOut, .unavailable:
                    clock.recordFailure(now: env.now(), timing: timing, jitter: env.jitter())
                    markWaiting(id, because: "signed out", now: env.now())
                    scheduleWake()
                    publish()
                }
            }
            return
        case .rateLimited(let retryAfter):
            SendLog.note("rate limited", id, "retryAfter=\(retryAfter.map { String(Int($0)) } ?? "-")")
            clock.recordRateLimit(now: now, retryAfter: retryAfter, timing: timing)
            transport.cancelBackground(itemId: id)
            markWaiting(id, because: "rate limited", now: now)
        case .offline:
            isOffline = true
            if (copies[id] ?? 0) > 0 {
                // iOS's copy waits for the network itself; the bubble still shows "waiting".
                noteCopyFailure(id, "offline", now: now)
            } else {
                markWaiting(id, because: "offline", now: now)
            }
        case .refreshAuth:
            // A second 401 straight after refreshing: treat like any passing failure.
            if !transientFailure(id, "token refused again", now: now) { return }
        case .transient(let why):
            if !transientFailure(id, why, now: now) { return }
        }
        scheduleWake()
        publish()
    }

    /// The direct copy failed but iOS still holds the background copy (it can sit on one for a long
    /// time when the server is unreachable). The message stays in flight — iOS may yet deliver it —
    /// but it now counts as failing: the bubble turns to "waiting" on the usual delay, and the
    /// shared clock retries it directly (pump) instead of leaving it to iOS's schedule.
    private func noteCopyFailure(_ id: UUID, _ why: String, now: Date) {
        SendLog.note("copy failed, other continues", id, why)
        outbox.update(id) {
            $0.lastError = why
            if $0.firstFailureAt == nil { $0.firstFailureAt = now }
        }
        if clock.isDue(now: now) { clock.recordFailure(now: now, timing: timing, jitter: env.jitter()) }
    }

    private func transientFailure(_ id: UUID, _ why: String, now: Date) -> Bool {
        if (copies[id] ?? 0) > 0 {
            noteCopyFailure(id, why, now: now)
            return true
        }
        // One round of failures moves the clock once: several messages failing together (the server
        // is down) mustn't escalate the backoff for each of them.
        if clock.isDue(now: now) { clock.recordFailure(now: now, timing: timing, jitter: env.jitter()) }
        markWaiting(id, because: why, now: now)
        return true
    }

    private func delivered(_ item: SendItem, _ message: Message, via: String) {
        SendLog.note("sent", item.id, "via=\(via) attempts=\(item.attempts)")
        transport.cancelBackground(itemId: item.id)   // the other copy, if still out
        forget(item, fileGrace: 10)
        clock.reset()
        env.cacheConfirmed(item.bookId, message)
        confirmations.send(SendConfirmation(bookId: item.bookId, clientId: item.id, message: message))
        pump("sent")   // a probe landed: everything behind it goes now
    }

    private func refuse(_ id: UUID, _ reason: String) {
        SendLog.note("refused", id, reason)
        transport.cancelBackground(itemId: id)
        outbox.update(id) { $0.status = .refused; $0.refusedReason = reason }
        copies[id] = nil
        builtPosts[id] = nil
        publish()
    }

    private func markWaiting(_ id: UUID, because reason: String, now: Date) {
        SendLog.note("waiting", id, reason)
        outbox.update(id) {
            $0.status = .waiting
            $0.lastError = reason
            if $0.firstFailureAt == nil { $0.firstFailureAt = now }
        }
        builtPosts[id] = nil
    }

    private func forget(_ item: SendItem, fileGrace: TimeInterval) {
        outbox.remove(item.id, fileGrace: fileGrace)
        copies[item.id] = nil
        builtPosts[item.id] = nil
        directInFlight.remove(item.id)
        refreshedAfter401.remove(item.id)
    }

    // MARK: - Timers

    /// One wake-up: the next retry, the next "sending → waiting" change on screen, or (offline)
    /// a periodic check in case the network-back event is missed.
    private func scheduleWake() {
        cancelWake?()
        cancelWake = nil
        let now = env.now()
        let unsent = outbox.items.filter { $0.status != .refused }
        guard !unsent.isEmpty else { return }
        var delays: [TimeInterval] = []
        if isOffline { delays.append(timing.offlineCheck) }
        if let due = clock.nextDue(after: now) { delays.append(due.timeIntervalSince(now)) }
        for item in unsent {
            if let since = item.firstFailureAt {
                let flip = since.addingTimeInterval(timing.waitingAfter).timeIntervalSince(now)
                if flip > 0 { delays.append(flip) }
            }
        }
        guard let delay = delays.min() else { return }
        cancelWake = env.schedule(max(delay, 0.05)) { [weak self] in self?.pump("retry clock") }
    }

    // MARK: - Helpers

    private func publish() {
        items = outbox.items.sorted { $0.sentAt < $1.sentAt }
    }

    func displayState(of item: SendItem) -> SendDisplayState {
        item.displayState(now: env.now(), waitingAfter: timing.waitingAfter, isOffline: isOffline)
    }

    nonisolated static func decode(_ body: Data?) -> Message? {
        body.flatMap { try? APIClient.decoder.decode(Message.self, from: $0) }
    }

    /// Preview text for a quoted reply (mirrors the server's ParentPreviewText).
    static func preview(of m: Message) -> String {
        if m.isDeleted { return "Deleted message" }
        switch m.type {
        case .text: return m.body ?? ""
        case .voice: return "🎤 Voice message"
        case .photo: return "📷 Photo"
        case .video: return "🎬 Video"
        case .unknown: return ""
        }
    }
}
