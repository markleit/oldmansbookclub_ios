import Combine
import Foundation

// #204 — sends every message the user taps Send on, as soon as possible, whatever happens next.
//
// App-level, started at launch (also when iOS launches the app in the background to report a
// transfer), and never tied to a screen: the chat only draws `items` and listens for
// `confirmations`. This replaces the send machinery that lived in BookViewModel — a per-chat queue,
// two watchdogs, several retry passes and their guards — which stopped the moment you left the chat.
//
// Design v2 (#204, 2026-10-12): three mechanisms, each with one job.
// - THE CARRIER: every unsent message always has one complete request with iOS's background
//   transfer, handed over at the tap while the app is in front, carrying the week-long send token.
//   iOS sends it when there's a network — app asleep, phone locked. A video's carrier is its upload
//   to a reserved blob; the server creates the message when the upload lands. A carrier that fails
//   for a passing reason is replaced at once, held by iOS until the shared clock is due.
// - THE FAST PATH: while the app is open it also sends directly, and retries directly on ONE shared
//   clock (1, 2, 4, 8, 15, 30 s, then every 60 s, no limit). Whichever copy lands first wins.
// - CONTINUED PROCESSING (iOS 26+, VideoSendKeeper): a video's compression and reservation keep
//   going after the user leaves — a speed-up; if iOS ends it, the next run finishes the job.
// A refusal stops with the server's reason. The rules are SendPolicy's; this class applies them.

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
    /// The token a send carries — the week-long send token (APIClient.sendToken); after a 401, a
    /// renewed one.
    var token: () async -> APIClient.SendToken
    var tokenAfterRejection: () async -> APIClient.SendToken
    /// Compresses a picked video (PR 5), reporting how far along it is (0–1). Default: can't, so the
    /// original is sent.
    var compressVideo: (_ source: URL, _ progress: @escaping (Double) -> Void) async -> VideoCompression = { _, _ in .unsupported }
    /// Continued processing for a video's work (VideoSendKeeper). Default: none.
    var videoWork: (VideoWork) -> Void = { _ in }
    /// Run `action` after `delay` seconds; returns a cancel function.
    var schedule: (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void
    /// Keep the saved chat in step when a message is confirmed with no chat open (A2).
    var cacheConfirmed: (_ bookId: UUID, _ message: Message) -> Void
    /// The force-quit reminder (PR 7): set, move, or (nil) cancel it.
    var reminder: (_ plan: ReminderPlan?) -> Void = { _ in }
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
    /// Carriers still being built: getting a token, or a video compressing and reserving. Leaving the
    /// foreground, and a background wake, wait for these (whenHandedOver).
    private var handingOver: [UUID: (attempt: Int, task: Task<Void, Never>)] = [:]
    /// 401s being answered: the token refresh, then handing the message back to iOS.
    private var refreshing: [UUID: Task<Void, Never>] = [:]
    /// What the force-quit reminder was last set for — it's only touched when that changes.
    private var reminderBasis: SendReminder.Basis?
    private var directInFlight: Set<UUID> = []
    private var refreshedAfter401: Set<UUID> = []
    /// Book of each message the user deleted while it was unsent — a late success for one (D1)
    /// still needs to reach its chat. (A message already confirmed isn't here: its other copy's
    /// late success is just a duplicate.)
    private var deletedBooks: [UUID: UUID] = [:]
    private var cancelWake: (() -> Void)?
    private var started = false
    /// Videos iOS is keeping going after the user left (continued processing), until it ends.
    private var keptAlive: Set<UUID> = []

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
        transport.onBackgroundProgress = { [weak self] key, sent, total in
            // A video's upload: the last quarter of its "Sending video" progress.
            guard case .blobUpload = key.step, total > 0 else { return }
            self?.env.videoWork(.progress(key.itemId, 0.75 + 0.25 * Double(sent) / Double(total)))
        }
        let taken = outbox.migrateLegacy()
        if taken > 0 { SendLog.note("migrated legacy", nil, "items=\(taken)") }
        // Before asking iOS what it holds: the share sheet's uploads are among them (PR 10).
        takeSharedMessages()
        isOffline = !env.hasNetwork()

        // Anything marked in flight by the last run: if iOS still holds a transfer for it, wait for
        // that; otherwise (the run ended before it went) it's ready again.
        let held = await transport.backgroundTaskKeys()
        for item in outbox.items where item.status == .inFlight {
            let count = held.filter { $0.itemId == item.id }.count
            if count == 0, item.shareSession != nil {
                // The share sheet's upload, in a session this run hasn't joined: iOS reports it
                // through a wake. Waited for — and sent directly too while the app is open.
                copies[item.id] = 1
                sendDirectIfPossible(item.id)
            } else if count > 0 {
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
    /// `compress`: a picked video, compressed after it's queued (PR 5) — the composer is free at once.
    func enqueueMedia(_ kind: SendItem.Kind, bookId: UUID, clubId: UUID, fileName: String, contentType: String,
                      durationSeconds: Int?, replyTo: Message?, compress: Bool = false) -> SendItem {
        let item = SendItem(id: UUID(), bookId: bookId, clubId: clubId, kind: kind,
                            sentAt: outbox.nextSentAt(now: env.now()), fileName: fileName, contentType: contentType,
                            durationSeconds: durationSeconds, parentMessageId: replyTo?.id,
                            parentSenderName: replyTo?.senderName, parentPreview: replyTo.map(Self.preview),
                            compressPending: compress ? true : nil)
        // A video's work outlasts the tap: ask iOS to keep it going if the user leaves. Only now —
        // Apple allows it only in response to the user's action, with the app in front.
        if kind == .video, env.isAppActive() {
            keptAlive.insert(item.id)
            env.videoWork(.start(item.id))
        }
        return enqueue(item)
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
        handingOver[id]?.task.cancel()   // a video still compressing stops now
        endVideoWork(item, success: false)
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

    /// The app is about to leave the foreground (Home, lock, another app). Nothing is handed over
    /// here: every unsent message already has its carrier with iOS (design v2) — except one whose
    /// carrier is still being built (a token being renewed; a video compressing or reserving). `done`
    /// runs once those are with iOS, so the caller keeps the app awake until then (iOS's ~30 s; a
    /// video also has continued processing).
    func appWillResignActive(done: @escaping () -> Void = {}) {
        if !handingOver.isEmpty { SendLog.note("leaving foreground: waiting for \(handingOver.count) carrier(s) being built") }
        updateReminder(rearm: true)
        whenHandedOver(done)
    }

    /// iOS ended a video's continued processing (expired, or the user cancelled it). Its compression
    /// stops; it starts again the next time the app runs. A video past compressing carries on: its
    /// reservation is one quick request, and its upload is with iOS.
    func videoWorkEnded(_ id: UUID) {
        keptAlive.remove(id)
        guard outbox.item(id)?.compressPending == true, let work = handingOver[id] else { return }
        SendLog.note("compression stopped until the app runs again", id)
        work.task.cancel()
    }

    /// Calls `done` once nothing is on its way to iOS: no carrier still being built, and no 401
    /// still renewing its token. The caller keeps the app awake until then — leaving the
    /// foreground, and a background wake (iOS may suspend the app as soon as it's told the wake is
    /// handled, and a refused carrier still has to be replaced).
    func whenHandedOver(_ done: @escaping () -> Void) {
        Task {
            // In rounds: a refresh ends in a new hand-over. Bounded, so a bookkeeping slip can't
            // keep the app awake forever.
            for _ in 0..<10 {
                // Not a video still compressing: that can take minutes, more than a wake or iOS's
                // ~30 s allows — continued processing keeps it going, or the next run does.
                let building = handingOver.filter { outbox.item($0.key)?.compressPending != true }
                let pending = building.values.map(\.task) + Array(refreshing.values)
                if pending.isEmpty { break }
                for task in pending { await task.value }
            }
            done()
        }
    }

    /// Where the Share extension leaves messages (PR 10); injectable for tests.
    var shareInbox: URL? = ShareInbox.defaultDirectory()

    /// Messages queued in the share sheet join the outbox (PR 10): one the extension handed to iOS
    /// is waited for (it's in flight; `start` checks iOS still has it), the rest are sent from here.
    /// Called at launch, on coming to the foreground, and when iOS wakes the app with the share
    /// sheet's results — before those results are read, so none arrives for a message not yet here.
    func takeSharedMessages() {
        guard let inbox = shareInbox else { return }
        let entries = ShareInbox.entries(in: inbox)
        guard !entries.isEmpty else { return }
        for entry in entries {
            defer { ShareInbox.remove(entry, in: inbox) }
            guard outbox.item(entry.id) == nil else { continue }
            var fileName: String?
            if let name = entry.fileName {
                // A copy: iOS may still be uploading from the inbox's file.
                fileName = try? outbox.importFile(at: inbox.appendingPathComponent(name), extension: "jpg", move: false)
                if fileName == nil { continue }
            }
            var item = SendItem(id: entry.id, bookId: entry.bookId, clubId: entry.clubId,
                                kind: entry.kind == .photo ? .photo : .text, sentAt: entry.sentAt, body: entry.body,
                                fileName: fileName, contentType: entry.kind == .photo ? "image/jpeg" : nil)
            if let session = entry.sessionIdentifier {
                item.status = .inFlight
                item.attempts = 1
                item.shareSession = session
                copies[entry.id] = 1
            }
            outbox.add(item)
            SendLog.note("from the share sheet", entry.id, entry.handedToIOS ? "with iOS" : "to send")
            // With the app open it goes directly too, as any message iOS holds does (dedup by id).
            if entry.handedToIOS { sendDirectIfPossible(entry.id) }
        }
        publish()
        pump("share sheet")
    }

    func appBecameActive() {
        takeSharedMessages()
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
        let online = env.hasNetwork()
        if !online {
            isOffline = true
        } else if isOffline {
            // The network is back but no "network back" event said so (the backup check found it):
            // do what the event does — fresh clock, and what iOS holds also goes directly.
            SendLog.note("network back (found by \(reason))")
            isOffline = false
            clock.reset()
            for item in outbox.items where item.status == .inFlight { sendDirectIfPossible(item.id) }
        }
        // The carrier invariant: whatever can have a carrier gets one now — online or not, backing
        // off or not. iOS holds it until there's a network and the clock is due, app asleep or not.
        let ids = SendPolicy.itemsToSubmit(outbox.items, clock: clock, now: now, isAppActive: env.isAppActive())
        if !ids.isEmpty { SendLog.note("pump", nil, "reason=\(reason) items=\(ids.count)") }
        let notBefore = clock.nextDue(after: now)
        for id in ids { submit(id, notBefore: notBefore) }
        // The fast path: what iOS holds but is failing also goes directly on the clock while the
        // app is open (sendDirectIfPossible) — only the oldest while backing off, as a probe.
        if online, clock.isDue(now: now) {
            for id in SendPolicy.directRetries(outbox.items, clock: clock) { sendDirectIfPossible(id) }
        }
        scheduleWake()
        publish()
    }

    /// `notBefore`: iOS holds the carrier until then (the retry clock). Returns the work of building
    /// it and handing it over, nil if there was nothing to submit.
    @discardableResult
    private func submit(_ id: UUID, notBefore: Date? = nil) -> Task<Void, Never>? {
        guard let item = outbox.item(id), item.status == .queued || item.status == .waiting else { return nil }
        let attempt = item.attempts + 1
        outbox.update(id) { $0.status = .inFlight; $0.attempts = attempt }
        copies[id] = 0
        let task = Task {
            await send(id, attempt: attempt, notBefore: notBefore)
            if handingOver[id]?.attempt == attempt { handingOver[id] = nil }
        }
        handingOver[id] = (attempt, task)
        return task
    }

    private func send(_ id: UUID, attempt: Int, notBefore: Date?) async {
        // A video is compressed first: it takes a while, and needs no token or network — but it needs
        // the app running: in front, or kept going for this video (continued processing).
        if outbox.item(id)?.compressPending == true {
            guard env.isAppActive() || keptAlive.contains(id) else {
                return couldNotBuild(id, attempt: attempt, "compresses when the app is open")
            }
            guard await compressVideo(id, attempt: attempt) else { return }
        }
        // A video's upload goes to a blob the server reserves, so with no network it can't have a
        // carrier at all: it waits for the network and the app.
        if let item = outbox.item(id), item.kind == .video, item.mediaUrl == nil, !env.hasNetwork() {
            isOffline = true
            return couldNotBuild(id, attempt: attempt, "offline: a video's upload is reserved first")
        }
        let token: String
        // No token: no carrier yet. It waits for sign-in or a renewed token, on the clock.
        switch await env.token() {
        case .token(let t): token = t
        case .signedOut: return couldNotBuild(id, attempt: attempt, "signed out")
        case .unavailable: return couldNotBuild(id, attempt: attempt, "token renewal unavailable")
        }
        guard let item = outbox.item(id), item.attempts == attempt else { return }
        if item.kind == .video && item.mediaUrl == nil {
            await reserveAndUpload(item, attempt: attempt, token: token, notBefore: notBefore)
        } else {
            post(item, attempt: attempt, token: token, notBefore: notBefore)
        }
    }

    /// A carrier can't be built yet (no token, a video offline or not yet compressed): the message
    /// waits on the clock, and on whatever it's waiting for (sign-in, the network, the app).
    private func couldNotBuild(_ id: UUID, attempt: Int, _ why: String) {
        guard let item = outbox.item(id), item.attempts == attempt else { return }
        copies[id] = nil
        markWaiting(id, because: why, now: env.now())
        endVideoWork(item, success: false)
        scheduleWake()
        publish()
    }

    private func post(_ item: SendItem, attempt: Int, token: String, notBefore: Date? = nil) {
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
            catch { return couldNotBuild(item.id, attempt: attempt, "couldn't write the request") }
        }
        builtPosts[item.id] = (key, built)
        transport.submitBackground(key, request: built.request, bodyFile: bodyFile, notBefore: notBefore)
        copies[item.id, default: 0] += 1
        SendLog.note("submit bg", item.id, "attempt=\(attempt) kind=\(item.kind.rawValue)"
                     + (notBefore.map { " notBefore=+\(Int($0.timeIntervalSince(env.now())))s" } ?? ""))

        // A carrier held until the retry clock is due goes only via iOS then; the fast path retries
        // directly on that same clock (pump).
        guard notBefore == nil, env.isAppActive() else { return }
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
            guard case .token(let token) = await env.token(),
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

    /// Compresses a queued video in place (PR 5). False when it can't be sent now: refused (too
    /// large, file gone), deleted meanwhile, or interrupted (the app was suspended mid-way — it
    /// starts again from the original on the next try).
    private func compressVideo(_ id: UUID, attempt: Int) async -> Bool {
        guard let item = outbox.item(id), let original = item.fileName, outbox.fileExists(original) else {
            refuse(id, "This message's file is missing from your phone, so it can't be sent.")
            return false
        }
        SendLog.note("compressing video", id)
        // Compressing is the first 70% of its "Sending video" progress.
        let result = await env.compressVideo(outbox.fileURL(original)) { [weak self] fraction in
            Task { @MainActor in self?.env.videoWork(.progress(id, 0.7 * fraction)) }
        }
        guard let current = outbox.item(id), current.attempts == attempt, current.status == .inFlight else {
            if case .compressed(let url) = result { try? FileManager.default.removeItem(at: url) }
            return false   // deleted, or moved on, while compressing
        }
        let sending: String
        switch result {
        case .compressed(let url):
            if let name = try? outbox.importFile(at: url, extension: "mp4") {
                sending = name
                outbox.update(id) { $0.originalFileName = original; $0.fileName = name }
            } else {
                SendLog.note("couldn't keep the compressed video, sending the original", id)
                sending = original
            }
        case .unsupported:
            SendLog.note("video compression failed, sending the original", id)
            sending = original
        case .interrupted:
            SendLog.note("video compression interrupted, will start again", id)
            outbox.update(id) { $0.status = .waiting }
            copies[id] = nil
            endVideoWork(current, success: false)
            scheduleWake()
            publish()
            return false
        }
        let bytes = outbox.fileSize(sending)
        if bytes > SendItem.maxVideoBytes {
            refuse(id, "Video is too large (max 100 MB).")
            return false
        }
        outbox.update(id) { $0.compressPending = nil }
        publish()
        SendLog.note("video ready", id, "bytes=\(bytes)")
        return true
    }

    /// The server's answer to a video reservation (POST /books/{id}/messages/video).
    private struct VideoReservation: Decodable {
        let uploadUrl: String?
        let mediaUrl: String?
        let message: Message?
    }

    /// A video's carrier (design v2): reserve its message — everything that can refuse it is checked
    /// then — and hand iOS one upload to the reserved blob. When the upload lands, the server
    /// creates the message itself, so nothing after the hand-over needs the app.
    private func reserveAndUpload(_ item: SendItem, attempt: Int, token: String, notBefore: Date?) async {
        guard let fileName = item.fileName, outbox.fileExists(fileName) else {
            return refuse(item.id, "This message's file is missing from your phone, so it can't be sent.")
        }
        let reserve = SendRequestBuilder.reserveVideo(item, baseURL: env.baseURL(), token: token, deviceId: env.deviceId())
        let response = await transport.sendDirect(reserve.request, body: reserve.jsonBody, bodyFile: nil)
        guard let current = outbox.item(item.id), current.attempts == attempt, current.status == .inFlight else { return }
        guard response.verdict == .delivered else {
            // No reservation, no carrier: a refusal stops it; anything else waits on the clock (a
            // 401 renews the token and tries again).
            return fail(item.id, attempt: attempt, response.verdict, replace: false)
        }
        let reservation = response.body.flatMap { try? APIClient.decoder.decode(VideoReservation.self, from: $0) }
        if let message = reservation?.message {
            return delivered(current, message, via: "reservation")   // a copy of this send already got through
        }
        guard let link = reservation?.uploadUrl.flatMap(URL.init(string:)), let mediaUrl = reservation?.mediaUrl else {
            return fail(item.id, attempt: attempt, .transient("unreadable reservation"), replace: false)
        }
        env.videoWork(.progress(item.id, 0.75))
        let built = SendRequestBuilder.blobUpload(uploadUrl: link, fileURL: outbox.fileURL(fileName),
                                                  contentType: item.contentType ?? "video/mp4")
        let key = SendTaskKey(itemId: item.id, attempt: attempt, step: .blobUpload(mediaUrl: mediaUrl))
        transport.submitBackground(key, request: built.request, bodyFile: outbox.fileURL(fileName), notBefore: notBefore)
        copies[item.id, default: 0] += 1
        SendLog.note("submit bg", item.id, "attempt=\(attempt) step=blob" + (env.isAppActive() ? "" : " from the background"))
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
            // The server creates the message from the upload (design v2). With the app open its
            // post confirms it at once (the server answers with the message it made); otherwise
            // it's confirmed when the app next runs, or by the live echo.
            SendLog.note("blob uploaded", id, "the server creates the message")
            outbox.update(id) { $0.mediaUrl = mediaUrl; $0.serverCreates = true; $0.status = .queued }
            copies[id] = nil
            endVideoWork(item, success: true)
            pump("blob uploaded")

        case (.blobUpload, .refused(let why)):
            // Storage, not the server, refused the upload: its link ran out (a week waiting), or
            // this is a repeat of an upload that already landed (create-only). Neither is the
            // message's fault — a fresh reservation either answers that it's sent or gives a new link.
            fail(id, attempt: key.attempt, .transient("upload refused by storage: \(why)"), direct: direct)

        default:
            fail(id, attempt: key.attempt, verdict, direct: direct)
        }
    }

    /// `replace`: a passing failure gets a new carrier at once, held by iOS until the clock is due
    /// (false when there's no carrier to replace — a video's reservation failed).
    private func fail(_ id: UUID, attempt: Int, _ verdict: SendVerdict, direct: Bool = false, replace: Bool = true) {
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
            refreshing[id] = Task {
                defer { refreshing[id] = nil }
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
            copies[id] = 0
            passingFailure(id, "rate limited", now: now, replace: replace)   // held until Retry-After
        case .offline:
            isOffline = true
            if (copies[id] ?? 0) > 0 {
                // iOS's copy waits for the network itself; the bubble still shows "waiting".
                noteCopyFailure(id, "offline", now: now)
            } else {
                passingFailure(id, "offline", now: now, replace: replace)
            }
        case .refreshAuth:
            // A second 401 straight after renewing: treat like any passing failure.
            passingFailure(id, "token refused again", now: now, replace: replace)
        case .transient(let why):
            passingFailure(id, why, now: now, replace: replace)
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

    /// A failure that can pass. While another copy is still out it only counts as failing. When
    /// the carrier itself failed, it's replaced at once — held by iOS until the clock is due — so the
    /// message always has one (design v2). Replaced from the background, iOS treats the new one as
    /// discretionary and may hold it longer: its rule, which no app can change.
    private func passingFailure(_ id: UUID, _ why: String, now: Date, replace: Bool) {
        if (copies[id] ?? 0) > 0 { return noteCopyFailure(id, why, now: now) }
        // One round of failures moves the clock once: several messages failing together (the server
        // is down) mustn't escalate the backoff for each of them.
        if clock.isDue(now: now) { clock.recordFailure(now: now, timing: timing, jitter: env.jitter()) }
        markWaiting(id, because: why, now: now)
        guard replace else {
            if let item = outbox.item(id) { endVideoWork(item, success: false) }
            return
        }
        SendLog.note("replacing carrier", id, env.isAppActive() ? "" : "from the background")
        submit(id, notBefore: clock.nextDue(after: now))
    }

    private func delivered(_ item: SendItem, _ message: Message, via: String) {
        SendLog.note("sent", item.id, "via=\(via) attempts=\(item.attempts)")
        endVideoWork(item, success: true)
        transport.cancelBackground(itemId: item.id)   // the other copy, if still out
        forget(item, fileGrace: 10)
        clock.reset()
        env.cacheConfirmed(item.bookId, message)
        confirmations.send(SendConfirmation(bookId: item.bookId, clientId: item.id, message: message))
        pump("sent")   // a probe landed: everything behind it goes now
    }

    private func refuse(_ id: UUID, _ reason: String) {
        SendLog.note("refused", id, reason)
        if let item = outbox.item(id) { endVideoWork(item, success: false) }
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

    /// A video's work is over (uploaded, sent, refused, deleted) or stopped until the app runs
    /// again: release its continued processing, if it has one.
    private func endVideoWork(_ item: SendItem, success: Bool) {
        guard item.kind == .video, keptAlive.remove(item.id) != nil else { return }
        env.videoWork(.finish(item.id, success: success))
    }

    private func forget(_ item: SendItem, fileGrace: TimeInterval) {
        outbox.remove(item.id, fileGrace: fileGrace)
        if let inbox = shareInbox { ShareInbox.removeFiles(for: item.id, in: inbox) }   // PR 10
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
        updateReminder()
    }

    /// Keeps the force-quit reminder in step with what's unsent (PR 7). `rearm`: set it again even
    /// if nothing changed — leaving the foreground, so one that fell due while the app was open
    /// (and so wasn't shown) still comes if the app is then swiped away.
    private func updateReminder(rearm: Bool = false) {
        let basis = SendReminder.basis(for: outbox.items)
        guard rearm || basis != reminderBasis else { return }
        reminderBasis = basis
        env.reminder(basis.map { SendReminder.plan($0, after: timing.reminderAfter, now: env.now()) })
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
