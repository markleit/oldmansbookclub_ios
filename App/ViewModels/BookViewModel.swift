import Foundation
import UIKit
import AVFoundation
import Network

@MainActor
final class BookViewModel: ObservableObject {
    @Published var book: Book
    @Published var messages: [Message] = [] {
        didSet { recomputeVisibleMessages() }   // #9
    }
    @Published var isLoadingMessages = false
    @Published var isLoadingOlderMessages = false
    @Published var reachedBeginning = false
    @Published var isOffline = false
    @Published var messageText = ""
    // The message being replied to (inline quoted reply), if any.
    @Published var replyingTo: Message?
    // "<First> is typing…" / "<First> is recording audio…" while someone else is
    // composing; auto-clears on a timeout so a dropped event can't leave it stuck.
    @Published var typingIndicator: String?
    private var typingClearWork: DispatchWorkItem?
    private var lastTypingSentAt: Date?
    private var recordingTypingTimer: Timer?
    @Published var errorMessage: String?
    @Published var showMicDeniedAlert = false
    @Published var blockedUserIds: Set<UUID> = [] {
        didSet { recomputeVisibleMessages() }   // #9
    }
    @Published var pendingImage: UIImage?
    @Published var pendingVideo: URL?
    @Published var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            // Keep the screen awake while recording so a long voice message isn't cut
            // off when the display auto-locks. Covers every start/stop/abort/error path
            // since they all flow through isRecording. Playback manages this flag
            // separately (AudioPlayerService); the two are mutually exclusive because
            // starting a recording stops playback first.
            UIApplication.shared.isIdleTimerDisabled = isRecording
        }
    }
    @Published var isUploading = false
    @Published var showSavedMessages = false
    @Published var savedMessages: [SavedMessage] = []
    @Published var isLoadingSaved = false
    @Published var messageSaved = false
    @Published var reads: [APIClient.ChatReadDto] = [] {
        didSet { recomputeReadFrontiers() }
    }
    // member userId -> sentAt of their last-seen message, for read receipts.
    private var readFrontierByUser: [UUID: Date] = [:]

    // #9: memoized — BookDetailView reads visibleMessages 20+ times per render, so recomputing
    // the filter on every access was pure waste. Now refreshed only when its inputs (messages /
    // blockedUserIds) change, via their didSet.
    @Published private(set) var visibleMessages: [Message] = []

    private func recomputeVisibleMessages() {
        visibleMessages = messages.filter { !blockedUserIds.contains($0.senderId) }
    }

    // Voice messages from others this device hasn't heard — drives "Mark all as read".
    // NOT a count: the number on screen always comes from the server (#119).
    var unheardVoiceMessages: [Message] {
        visibleMessages.filter {
            $0.type == .voice && !$0.isDeleted
                && $0.senderId != TokenStore.shared.userId
                && !HeardStore.shared.isHeard($0.id)
        }
    }

    // Consuming a voice message drops the count by one straight away; the server's answer to
    // the receipt replaces it a moment later (UnreadStore.set via ReceiptQueue).
    //
    // Only others' voice counts. Playing your own message completes too, but the server has
    // nothing to record for it — an id it won't accept would sit in the outbox being retried
    // forever.
    func consumeHeard(_ ids: [UUID]) {
        let myId = TokenStore.shared.userId
        let byOthers = Set(messages.filter { $0.type == .voice && $0.senderId != myId }.map(\.id))
        let consumable = ids.filter { byOthers.contains($0) && !HeardStore.shared.isHeard($0) }
        guard !consumable.isEmpty else { return }
        HeardStore.shared.markHeard(consumable, bookId: book.id)
        UnreadStore.shared.bump(bookId: book.id, by: -consumable.count)
        Task { await ReceiptQueue.shared.pushHeard(bookId: book.id, ids: consumable) }
    }

    private func recomputeReadFrontiers() {
        let sentById = Dictionary(messages.map { ($0.id, $0.sentAt) }, uniquingKeysWith: { first, _ in first })
        var map: [UUID: Date] = [:]
        for r in reads where sentById[r.lastSeenMessageId] != nil {
            map[r.userId] = sentById[r.lastSeenMessageId]
        }
        readFrontierByUser = map
    }

    // Members who have "read" the given message. Voice messages count only when the
    // member has actually heard them (server heard-set); text/photo/video use the
    // last-seen frontier (their last-seen is this message or newer).
    func readers(of message: Message) -> [APIClient.ChatReadDto] {
        if message.type == .voice {
            return reads.filter { $0.heardMessageIds.contains(message.id) }
        }
        return reads.filter { (readFrontierByUser[$0.userId] ?? .distantPast) >= message.sentAt }
    }

    // MARK: - Typing indicator

    // Incoming: show "<First> is typing/recording…" and (re)arm the auto-clear.
    private func handleUserTyping(_ p: UserTypingPayload) {
        guard p.bookId == book.id, p.userId != TokenStore.shared.userId else { return }
        // Server already supplies the display name (full nickname, or first name of a
        // real name) — show as-is.
        let name = p.displayName
        typingIndicator = p.isRecording ? "\(name) is talking…" : "\(name) is typing…"
        typingClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.typingIndicator = nil }
        typingClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    // Outgoing (text): throttle to ~once per 2s so we don't ping per keystroke.
    func notifyTyping() {
        guard !messageText.isEmpty else { return }
        let now = Date()
        if let last = lastTypingSentAt, now.timeIntervalSince(last) < 2 { return }
        lastTypingSentAt = now
        ChatService.shared.sendTyping(bookId: book.id, isRecording: false)
    }

    // Outgoing (recording): ping now + repeat every 2s so the indicator doesn't time
    // out during a long recording. Stopped in stopRecordingTypingPings().
    private func startRecordingTypingPings() {
        ChatService.shared.sendTyping(bookId: book.id, isRecording: true)
        recordingTypingTimer?.invalidate()
        recordingTypingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in ChatService.shared.sendTyping(bookId: self.book.id, isRecording: true) }
        }
    }

    private func stopRecordingTypingPings() {
        recordingTypingTimer?.invalidate()
        recordingTypingTimer = nil
    }

    // Live read receipt: upsert the reader's last-seen marker (keeping their heard set).
    private func applyReadReceipt(_ p: ReadReceiptPayload) {
        let heard = reads.first(where: { $0.userId == p.userId })?.heardMessageIds ?? []
        reads.removeAll { $0.userId == p.userId }
        reads.append(APIClient.ChatReadDto(userId: p.userId, displayName: p.displayName,
            avatarUrl: p.avatarUrl, lastSeenMessageId: p.lastSeenMessageId, heardMessageIds: heard))
    }

    // Live heard receipt: union the newly-heard voice ids into the reader's heard set
    // (keeping their last-seen marker).
    private func applyHeardReceipt(_ p: HeardReceiptPayload) {
        let existing = reads.first(where: { $0.userId == p.userId })
        var heard = Set(existing?.heardMessageIds ?? [])
        heard.formUnion(p.messageIds)
        let lastSeen = existing?.lastSeenMessageId ?? p.messageIds.first ?? p.userId
        reads.removeAll { $0.userId == p.userId }
        reads.append(APIClient.ChatReadDto(userId: p.userId, displayName: p.displayName,
            avatarUrl: p.avatarUrl, lastSeenMessageId: lastSeen, heardMessageIds: Array(heard)))
    }

    // #47: apply a live reaction receipt — upsert (or remove) this user's reaction on the
    // target message. Per-user set, so a switch/remove resolves cleanly.
    private func applyReactionReceipt(_ p: ReactionReceiptPayload) {
        guard p.bookId == book.id, let idx = messages.firstIndex(where: { $0.id == p.messageId }) else { return }
        var reactions = messages[idx].reactions ?? []
        reactions.removeAll { $0.userId == p.userId }
        if let emoji = p.emoji { reactions.append(MessageReaction(userId: p.userId, emoji: emoji)) }
        messages[idx].reactions = reactions.isEmpty ? nil : reactions
    }

    // #47: toggle the caller's reaction — tapping the current emoji removes it, a different one
    // switches. Optimistic local update; the server broadcast reconciles everyone (and a failed
    // call heals on the next load).
    func toggleReaction(_ emoji: String, on message: Message) {
        guard let me = TokenStore.shared.userId,
              let idx = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let removing = messages[idx].myReactionEmoji == emoji
        var reactions = messages[idx].reactions ?? []
        reactions.removeAll { $0.userId == me }
        if !removing { reactions.append(MessageReaction(userId: me, emoji: emoji)) }
        messages[idx].reactions = reactions.isEmpty ? nil : reactions

        let bookId = book.id
        let messageId = message.id
        Task {
            do {
                if removing { try await APIClient.shared.removeReaction(bookId: bookId, messageId: messageId) }
                else { try await APIClient.shared.setReaction(bookId: bookId, messageId: messageId, emoji: emoji) }
            } catch {
                // Best-effort — reconciles on the next load() if the write didn't land.
            }
        }
    }

    // #107: a heard receipt from this user's OWN other device. Mirror the #102 seed logic —
    // mark those voice ids heard in the device-local store (sticky/additive, skipping anything
    // already completed so an in-progress playback isn't disturbed), then refresh the unread
    // count. Never touches `reads`, so self can't appear in the "heard-by" avatar row (#108).
    private func applySelfHeardReceipt(_ p: HeardReceiptPayload) {
        let newlyHeard = p.messageIds.filter { !HeardStore.shared.isHeard($0) }
        guard !newlyHeard.isEmpty else { return }
        // The other device already told the server, so this is confirmed truth, not a mark to
        // send. Move the scrubbers to the end to match, and drop the count optimistically —
        // the next consuming action or books load reconciles it.
        let durationById = Dictionary(messages.map { ($0.id, $0.durationSeconds ?? 0) },
                                      uniquingKeysWith: { first, _ in first })
        PlaybackProgressStore.shared.markHeard(newlyHeard.map { (id: $0, duration: durationById[$0] ?? 0) })
        HeardStore.shared.confirm(newlyHeard)
        UnreadStore.shared.bump(bookId: book.id, by: -newlyHeard.count)
    }

    // Optimistic text messages awaiting their server echo, tracked by clientId (the
    // server echoes it back). Keyed by id — not body — so identical consecutive sends
    // don't clobber each other (#35).
    private var pendingTextIds: Set<UUID> = []
    private var currentlySendingMedia: Set<UUID> = []
    // Echo-timeout watchdogs keyed by item id so we can cancel them when the app
    // backgrounds (a frozen timer would otherwise fire on resume and falsely mark an
    // in-flight send as failed) and replace them on re-send.
    private var echoTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    // App-lifecycle observers: re-flush pending media when we return to the foreground,
    // cancel echo watchdogs when we leave it. Registered once (see startLifecycleObservers).
    private var appActiveObserver: NSObjectProtocol?
    private var appBackgroundObserver: NSObjectProtocol?
    private var uploadCompletedObserver: NSObjectProtocol?
    private var sendCompletedObserver: NSObjectProtocol?
    private var audioInterruptionObserver: NSObjectProtocol?
    private let audioRecorder = AudioRecorder()
    private var networkMonitor: NWPathMonitor?
    private var recordingStartTime: Date?
    private let maxAutoRetries = 5

    init(book: Book) {
        self.book = book
    }

    func load() async {
        // This chat now owns its unread count (see UnreadStore.setActiveBook); a concurrent
        // foreground library reload must not clobber it with lagging server truth.
        UnreadStore.shared.setActiveBook(book.id)
        // A background push wake may have warmed this cache already, so the chat renders
        // instantly instead of waiting on the fetch below.
        let cached = ChatCache.load(bookId: book.id)
        let hasCachedState = !cached.isEmpty
        if hasCachedState {
            messages = cached
            // #146 — the cache deliberately excludes un-confirmed sends, so seeding from it
            // blanks any pending bubble. Restore immediately rather than waiting for the fetch
            // below to resolve: on a dead network that fetch can park for its full resource
            // timeout, and until #146 those seconds were a window where a failed send simply
            // wasn't on screen (reported from device testing as "the message disappeared, then
            // came back when airplane mode was toggled off" — it was queued and safe the whole
            // time, just invisible). Also covers the early-return paths below, which skip the
            // restore calls entirely.
            restorePendingMediaBubbles()
            restorePendingTextBubbles()
        }
        isOffline = false
        isLoadingMessages = !hasCachedState
        reachedBeginning = false

        let bookId = book.id

        // Fire messages, blocked, and reads all in parallel — they're independent
        async let messagesFetch = APIClient.shared.getMessages(bookId: bookId)
        async let blockedFetch = APIClient.shared.fetchBlockedUserIds()
        async let readsFetch = APIClient.shared.getReads(bookId: bookId)
        // The server's per-account heard state — seed the device-local heard cache from it so a
        // voice heard on another device shows as heard here too, and counts match (#102).
        async let myHeardFetch = APIClient.shared.myHeardMessageIds(bookId: bookId)

        do {
            let fetched = try await messagesFetch
            // Merge by id so previously-paginated older messages and unconfirmed optimistic
            // entries survive across refresh; fresh fetch wins on overlapping ids (server-side
            // edits propagate). Reconciled client ids are the confirmed sends whose optimistic
            // copy was dropped — clear each one's queue/pending entry even when the optimistic
            // copy ISN'T in memory: on a cold launch the cache excludes pending sends, so the
            // entry would otherwise survive and restorePendingMediaBubbles would resurrect it as
            // a ghost that can never reconcile (its re-send echo is dropped because the server id
            // is already loaded here) and stick permanently on .failed.
            let merged = ChatCache.merge(existing: messages, incoming: fetched, myUserId: TokenStore.shared.userId)
            messages = merged.messages
            for cid in merged.reconciledClientIds { clearPendingSend(clientId: cid) }
            saveMessagesCache()
            prefetchRecentVoiceAudio()

            // Restore any media/text messages that were pending when the app was last closed
            restorePendingMediaBubbles()
            restorePendingTextBubbles()
        } catch is CancellationError {
            isLoadingMessages = false
            return
        } catch {
            if hasCachedState {
                isOffline = true
                // Keep any pending media/text items visible while offline
                restorePendingMediaBubbles()
                restorePendingTextBubbles()
            } else {
                errorMessage = "Failed to load discussion."
            }
        }
        isLoadingMessages = false
        startNetworkMonitorIfNeeded()
        startLifecycleObservers()

        guard !isOffline else { return }

        // Newest SERVER-known message: an optimistic send still in flight has an id the server
        // has never seen, and the read marker must point at a real message (#119).
        let latestId = messages.first(where: { $0.sendState == nil })?.id

        if let ids = try? await blockedFetch { blockedUserIds = Set(ids) }
        if let fetched = try? await readsFetch { reads = fetched }

        // Reconcile this device's heard cache with the server's per-account heard state (#102,
        // #119): the server's answer wins for anything we have data on, marks still waiting in
        // the outbox survive, and the ids the server is missing come back to be pushed up.
        if let heardIds = try? await myHeardFetch {
            let myId = TokenStore.shared.userId
            let voice = messages.filter { $0.type == .voice && $0.senderId != myId }
            let durationById = Dictionary(voice.map { ($0.id, $0.durationSeconds ?? 0) },
                                          uniquingKeysWith: { first, _ in first })
            let toPush = HeardStore.shared.seed(
                serverHeardIds: heardIds,
                voiceIds: voice.map(\.id),
                legacyHeardIds: PlaybackProgressStore.shared.legacyHeardIds(among: voice.map(\.id)),
                bookId: bookId)
            // Park the scrubbers of anything newly known-heard at the end.
            let toPosition = heardIds
                .filter { !PlaybackProgressStore.shared.isCompleted($0) }
                .map { (id: $0, duration: durationById[$0] ?? 0) }
            if !toPosition.isEmpty { PlaybackProgressStore.shared.markHeard(toPosition) }
            if !toPush.isEmpty { await ReceiptQueue.shared.pushHeard(bookId: bookId, ids: toPush) }
        }

        // markRead fires after messages resolved (needs latestId). Its response carries the
        // book's fresh unread count, which lands in UnreadStore — so opening a chat resyncs
        // the number rather than recomputing it here.
        if let id = latestId {
            await ReceiptQueue.shared.markRead(bookId: bookId, messageId: id)
        }

        await ChatService.shared.setOnMessageReceived { [weak self] message in
            guard let self, message.clubId == self.book.clubId else { return }

            // Any SignalR receive proves we're online — clear the stale offline banner.
            self.markOnline()

            // Prefetch the audio so tapping play is instant by the time the user does.
            if message.type == .voice, let u = message.mediaUrl, let url = URL(string: u) {
                AudioCache.shared.prefetch(url)
            }

            // Drop SignalR replays on auto-reconnect (same server ID already in list)
            guard !self.messages.contains(where: { $0.id == message.id }) else { return }

            self.reconcileConfirmedMessage(message)
        }

        await ChatService.shared.setOnMessageDeleted { [weak self] messageId in
            guard let self else { return }
            if let idx = self.messages.firstIndex(where: { $0.id == messageId }) {
                self.messages[idx].isDeleted = true
                self.messages[idx].body = nil
                self.messages[idx].mediaUrl = nil
                self.messages[idx].durationSeconds = nil
                self.saveMessagesCache()
            }
        }

        await ChatService.shared.setOnMessageEdited { [weak self] payload in
            guard let self, payload.bookId == self.book.id else { return }
            if let idx = self.messages.firstIndex(where: { $0.id == payload.messageId }), !self.messages[idx].isDeleted {
                self.messages[idx].body = payload.body
                self.saveMessagesCache()
            }
        }

        await ChatService.shared.setOnReadReceipt { [weak self] payload in
            guard let self, payload.bookId == self.book.id,
                  payload.userId != TokenStore.shared.userId else { return }
            self.applyReadReceipt(payload)
        }

        await ChatService.shared.setOnHeardReceipt { [weak self] payload in
            guard let self, payload.bookId == self.book.id else { return }
            if payload.userId == TokenStore.shared.userId {
                // #107: a heard receipt echoed from THIS user's OWN other device. Sync the
                // local heard state + unread count so counts track across devices live.
                // Deliberately NOT routed through applyHeardReceipt, so self never lands in
                // the "heard-by" avatar row (#108).
                self.applySelfHeardReceipt(payload)
            } else {
                self.applyHeardReceipt(payload)
            }
        }

        await ChatService.shared.setOnReactionReceipt { [weak self] payload in
            self?.applyReactionReceipt(payload)
        }

        await ChatService.shared.setOnUserTyping { [weak self] payload in
            self?.handleUserTyping(payload)
        }

        await ChatService.shared.connect(bookId: book.id)
        await flushPendingMedia()
    }

    // Re-insert optimistic bubbles for any media items still in the queue. Marks them
    // .failed by default — flushPendingMedia will flip them to .sending and resend.
    private func restorePendingMediaBubbles() {
        let pending = MediaSendQueue.shared.items.filter { $0.bookId == book.id }
        guard let userId = TokenStore.shared.userId else { return }
        for item in pending where !messages.contains(where: { $0.id == item.id }) {
            let type: MessageType
            switch item.kind {
            case .voice: type = .voice
            case .photo: type = .photo
            case .video: type = .video
            }
            let restored = Message(
                id: item.id,
                clubId: item.clubId,
                senderId: userId,
                senderName: TokenStore.shared.nickname ?? TokenStore.shared.displayName ?? "",
                type: type,
                mediaUrl: item.localFileUrl.absoluteString,
                durationSeconds: item.durationSeconds,
                sentAt: Date(),
                sendState: .failed,
                clientId: item.id
            )
            messages.insert(restored, at: 0)
        }
    }

    func sendMessage() async {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        guard let userId = TokenStore.shared.userId else {
            errorMessage = "Session error — please sign out and back in."
            return
        }
        messageText = ""
        let reply = replyingTo
        replyingTo = nil

        let clientId = UUID()
        let optimistic = Message(
            id: clientId,
            clubId: book.clubId,
            senderId: userId,
            senderName: TokenStore.shared.nickname ?? TokenStore.shared.displayName ?? "",
            type: .text,
            body: text,
            mediaUrl: nil,
            durationSeconds: nil,
            sentAt: Date(),
            parentMessageId: reply?.id,
            parentSenderName: reply?.senderName,
            parentPreview: reply.map(replyPreview)
        )
        messages.insert(optimistic, at: 0)
        pendingTextIds.insert(clientId)

        // #146 — persisted BEFORE the network call, so a force-quit at any point (mid-call, or
        // even before it starts) leaves a durable record: restorePendingTextBubbles() picks it
        // back up on relaunch instead of losing it with zero trace (confirmed nothing else
        // persists an in-flight text send). A text body is small enough that the network call
        // itself always finishes well inside BackgroundTaskBox's ~30s grace — this queue exists
        // for durability across a kill, not to extend how long the call is allowed to run.
        TextSendQueue.shared.enqueue(TextSendQueue.PendingSend(
            clientId: clientId, bookId: book.id, clubId: book.clubId,
            body: text, parentMessageId: reply?.id, queuedAt: Date()))

        let bgTask = BackgroundTaskBox(name: "send-text-\(clientId.uuidString)")
        defer { bgTask.end() }
        do {
            let sent = try await APIClient.shared.sendMessage(
                bookId: book.id, type: .text, body: text, clientId: clientId, parentMessageId: reply?.id)
            markOnline()
            TextSendQueue.shared.remove(clientId: clientId)
            reconcileConfirmedMessage(sent)
        } catch {
            // #146 — a permanent refusal (4xx: validation, rate limit) is a real answer, not an
            // outage; retrying can't change it, so it's dropped rather than left to retry
            // forever. Anything else (no network, 5xx) stays queued — the bubble goes .failed
            // (not removed) and flushPendingText() retries it on the next foreground/load,
            // same as a failed media send, instead of silently vanishing.
            if TextSendQueue.shared.isPermanentRefusal(error) {
                TextSendQueue.shared.remove(clientId: clientId)
                pendingTextIds.remove(clientId)
                messages.removeAll { $0.id == clientId }
            } else if let idx = messages.firstIndex(where: { $0.id == clientId }) {
                messages[idx].sendState = .failed
            }
            if case ChatError.serverError(let msg) = error {
                errorMessage = msg
            } else {
                errorMessage = "Failed to send — connection lost. Please try again."
            }
        }
    }

    // #146 — retry a failed text send (mirrors retryMediaMessage). Manual retry from the
    // failed-message action menu, or driven automatically by flushPendingText().
    func retryTextMessage(id: UUID) async {
        guard let item = TextSendQueue.shared.items.first(where: { $0.clientId == id }) else { return }
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].sendState = .sending
        }
        do {
            let sent = try await APIClient.shared.sendMessage(
                bookId: item.bookId, type: .text, body: item.body, clientId: item.clientId,
                parentMessageId: item.parentMessageId)
            markOnline()
            TextSendQueue.shared.remove(clientId: item.clientId)
            reconcileConfirmedMessage(sent)
        } catch {
            if TextSendQueue.shared.isPermanentRefusal(error) {
                TextSendQueue.shared.remove(clientId: item.clientId)
                pendingTextIds.remove(item.clientId)
                messages.removeAll { $0.id == item.clientId }
            } else if let idx = messages.firstIndex(where: { $0.id == item.clientId }) {
                messages[idx].sendState = .failed
            }
        }
    }

    private var isFlushingText = false

    // #146 — same guard-against-overlap reasoning as flushPendingMedia (#37): foreground-resume
    // and a fresh load() can both trigger this.
    private func flushPendingText() async {
        guard !isFlushingText else { return }
        isFlushingText = true
        defer { isFlushingText = false }
        for item in TextSendQueue.shared.items(for: book.id) {
            await retryTextMessage(id: item.clientId)
        }
    }

    // Re-insert optimistic bubbles for any text sends still in the queue after a relaunch —
    // mirrors restorePendingMediaBubbles(). Marked .failed; flushPendingText() will flip them
    // to .sending and retry.
    private func restorePendingTextBubbles() {
        let pending = TextSendQueue.shared.items(for: book.id)
        guard let userId = TokenStore.shared.userId else { return }
        for item in pending where !messages.contains(where: { $0.id == item.clientId }) {
            let restored = Message(
                id: item.clientId,
                clubId: item.clubId,
                senderId: userId,
                senderName: TokenStore.shared.nickname ?? TokenStore.shared.displayName ?? "",
                type: .text,
                body: item.body,
                sentAt: item.queuedAt,
                sendState: .failed,
                clientId: item.clientId,
                parentMessageId: item.parentMessageId
            )
            messages.insert(restored, at: 0)
            pendingTextIds.insert(item.clientId)
        }
    }

    func sendPhoto() async {
        guard let image = pendingImage,
              let data = image.resizedForUpload().jpegData(compressionQuality: 0.7),
              let userId = TokenStore.shared.userId,
              let persistentUrl = MediaSendQueue.shared.saveToQueue(data: data, extension: "jpg")
        else { return }
        pendingImage = nil
        await enqueueAndSendMedia(
            kind: .photo, contentType: "image/jpeg", durationSeconds: nil,
            persistentUrl: persistentUrl, userId: userId
        )
    }

    func sendVideo() async {
        guard let videoUrl = pendingVideo, let userId = TokenStore.shared.userId else { return }

        // Duration isn't affected by compression, so check it against the source first —
        // cheapest way to reject an obviously-too-long clip before spending time compressing it.
        let duration = (try? await AVURLAsset(url: videoUrl).load(.duration))?.seconds ?? 0
        if duration > 300 {
            pendingVideo = nil
            errorMessage = "Video is too long (max 5 minutes). Please trim it and try again."
            return
        }

        // #146 — compress before the size check and before queueing (mirrors sendPhoto's
        // resizedForUpload): video was previously sent unencoded, so a normal phone-shot clip a
        // few minutes long routinely exceeded the 100MB cap well before hitting the 5-minute
        // duration cap. Falls back to the original file if compression fails for any reason
        // (unsupported format, disk pressure) rather than blocking the send outright.
        let compressedUrl = await compressedVideo(from: videoUrl) ?? videoUrl

        let attrs = try? FileManager.default.attributesOfItem(atPath: compressedUrl.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if fileSize > 100 * 1024 * 1024 {
            pendingVideo = nil
            errorMessage = "Video is too large (max 100 MB)."
            return
        }

        guard let persistentUrl = MediaSendQueue.shared.moveToQueue(from: compressedUrl, extension: "mp4") else { return }
        pendingVideo = nil
        await enqueueAndSendMedia(
            kind: .video, contentType: "video/mp4", durationSeconds: nil,
            persistentUrl: persistentUrl, userId: userId
        )
    }

    // #146 — 720p H.264/AAC, matching sendPhoto's "resize before upload" treatment for video.
    // Caps resolution rather than targeting a bitrate directly: AVAssetExportSession doesn't
    // upscale, so an already-small source (e.g. already 720p or below) passes through roughly
    // unchanged, while a 1080p/4K phone recording — the common case that blew past the 100MB cap
    // — gets meaningfully smaller. Returns nil (caller falls back to the original file) if the
    // asset can't be exported at this preset or the export otherwise fails.
    private func compressedVideo(from url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
        let outputUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        export.outputURL = outputUrl
        export.outputFileType = .mp4
        // exportAsynchronously's completion-handler API, not the iOS 18+ `export(to:as:)` async
        // method — deployment target here is iOS 16.
        await withCheckedContinuation { continuation in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: outputUrl)
            return nil
        }
        return outputUrl
    }

    // Shared optimistic-insert + enqueue + send entry point for all media kinds.
    private func enqueueAndSendMedia(
        kind: MediaQueueKind,
        contentType: String,
        durationSeconds: Int?,
        persistentUrl: URL,
        userId: UUID
    ) async {
        let localId = UUID()
        let reply = replyingTo
        replyingTo = nil
        let messageType: MessageType
        switch kind {
        case .voice: messageType = .voice
        case .photo: messageType = .photo
        case .video: messageType = .video
        }
        let optimistic = Message(
            id: localId,
            clubId: book.clubId,
            senderId: userId,
            senderName: TokenStore.shared.nickname ?? TokenStore.shared.displayName ?? "",
            type: messageType,
            mediaUrl: persistentUrl.absoluteString,
            durationSeconds: durationSeconds,
            sentAt: Date(),
            sendState: .sending,
            clientId: localId,
            parentMessageId: reply?.id,
            parentSenderName: reply?.senderName,
            parentPreview: reply.map(replyPreview)
        )
        messages.insert(optimistic, at: 0)

        let item = MediaQueueItem(
            id: localId,
            bookId: book.id,
            clubId: book.clubId,
            kind: kind,
            fileName: persistentUrl.lastPathComponent,
            contentType: contentType,
            durationSeconds: durationSeconds,
            uploadedMediaUrl: nil,
            retryCount: 0,
            parentMessageId: reply?.id
        )
        MediaSendQueue.shared.enqueue(item)
        await sendMediaItem(item)
    }

    func toggleRecording() async {
        if isRecording { await stopRecording() } else { await startRecording() }
    }

    func startRecording() async {
        guard !isRecording else { return }
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
        guard granted else { showMicDeniedAlert = true; return }
        // Stop any active playback FIRST (recording is the primary action; the player
        // and recorder must not share the playAndRecord session, which would mix the
        // playing audio into the capture). This must happen before claiming isRecording
        // below: stopAll -> stopCurrentPlayer re-enables the idle timer, so if we
        // claimed isRecording first its didSet would disable the timer and then stopAll
        // would immediately turn it back on — leaving the screen free to lock mid-
        // recording. Order matters; keep stopAll above isRecording = true.
        AudioPlayerService.shared.stopAll(deactivateSession: false)
        // Claim the recording state up front. The start chirp below awaits (~150ms);
        // in press-and-hold mode a quick release fires stopRecording during that await.
        // If we didn't set isRecording first, stopRecording's `guard isRecording` would
        // make it a no-op and the recorder would start AFTER release — a stuck recording
        // that mimics tap-to-talk. Claiming it here lets a release during the chirp
        // cancel the start, and its didSet disables the idle timer for the recording.
        isRecording = true
        // "Mic is open" chirp (walkie-talkie style). Returns the audio-device-clock time
        // after which capture can begin without the tone bleeding in; the recorder starts
        // exactly then via record(atTime:) (deterministic — no sleep). nil = cue disabled.
        let recordAt = await AudioCue.shared.playRecordStart()
        // Released during the chirp → stopRecording already flipped isRecording off; abort.
        guard isRecording else { return }
        do {
            try audioRecorder.start(atTime: recordAt)
            recordingStartTime = Date()
            startRecordingTypingPings()   // broadcast "is recording audio…"
        } catch {
            isRecording = false
            errorMessage = "Could not start recording."
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        isRecording = false
        stopRecordingTypingPings()
        let elapsed = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartTime = nil
        let recording = audioRecorder.stop()
        // "Mic closed" chirp — capture has ended, so it won't be in the recording.
        // Plays on close regardless of whether the take is kept or discarded.
        AudioCue.shared.playRecordStop()
        guard let (tempUrl, duration) = recording else { return }
        guard elapsed >= 0.5 else { return }
        guard let persistentUrl = MediaSendQueue.shared.moveToQueue(from: tempUrl, extension: "m4a"),
              let userId = TokenStore.shared.userId else { return }

        await enqueueAndSendMedia(
            kind: .voice, contentType: "audio/mp4", durationSeconds: duration,
            persistentUrl: persistentUrl, userId: userId
        )
    }

    /// Drop an in-progress take when recording is interrupted by backgrounding or a
    /// call/Siri/alarm (#75). Such a take is truncated and was never deliberately
    /// finished, so we discard rather than send a fragment — and silently, since the
    /// audio is gone regardless and a banner on every return is more nag than help.
    /// No send, no wall-clock duration math, no user notice. A no-op when not recording.
    func discardRecording() {
        guard isRecording else { return }
        isRecording = false               // didSet re-enables the idle timer
        stopRecordingTypingPings()
        recordingStartTime = nil
        audioRecorder.discard()
    }

    func retryMediaMessage(id: UUID) async {
        // Manual retry resets the auto-retry budget so the user can always try again,
        // even after the automatic attempts were exhausted (retryCount hit the ceiling).
        MediaSendQueue.shared.resetRetry(id: id)
        guard let item = MediaSendQueue.shared.items.first(where: { $0.id == id }) else { return }
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].sendState = .sending
        }
        await sendMediaItem(item)
    }

    // Warm the audio cache for the most recent voice messages so playback starts
    // instantly. AudioCache dedupes and skips already-cached / non-https URLs.
    private func prefetchRecentVoiceAudio(limit: Int = 15) {
        var count = 0
        for m in messages where m.type == .voice {
            guard let u = m.mediaUrl, let url = URL(string: u) else { continue }
            AudioCache.shared.prefetch(url)
            count += 1
            if count >= limit { break }
        }
    }

    // Reconciliation cleanup when load() finds a confirmed server message for one of
    // our optimistic sends (the live echo was missed): drop the media queue entry and
    // schedule its local file for deletion, and clear any pending-text bookkeeping.
    private func clearPendingSend(clientId: UUID) {
        if let item = MediaSendQueue.shared.items.first(where: { $0.id == clientId }) {
            MediaSendQueue.shared.remove(id: clientId)
            MediaSendQueue.shared.scheduleCleanup(fileName: item.fileName)
        }
        // #146 — a fresh getMessages() fetch can reconcile a queued text send the server
        // actually received even before flushPendingText() got to it (e.g. it landed right
        // before a force-quit) — clear the queue entry so it isn't resent as a duplicate attempt.
        TextSendQueue.shared.remove(clientId: clientId)
        pendingTextIds.remove(clientId)
    }

    func cancelMediaMessage(id: UUID) {
        if let item = MediaSendQueue.shared.items.first(where: { $0.id == id }) {
            MediaSendQueue.shared.cleanupFile(for: item)
            MediaSendQueue.shared.remove(id: id)
        }
        messages.removeAll { $0.id == id }
    }

    // #146 — mirrors cancelMediaMessage, for a failed text send the user chooses not to retry.
    func cancelTextMessage(id: UUID) {
        TextSendQueue.shared.remove(clientId: id)
        pendingTextIds.remove(id)
        messages.removeAll { $0.id == id }
    }

    private func sendMediaItem(_ item: MediaQueueItem) async {
        guard !currentlySendingMedia.contains(item.id) else { return }
        guard item.retryCount < maxAutoRetries else {
            if let idx = messages.firstIndex(where: { $0.id == item.id }) {
                messages[idx].sendState = .failed
            }
            return
        }
        currentlySendingMedia.insert(item.id)
        defer { currentlySendingMedia.remove(item.id) }
        // Hold a background-task assertion across the foreground work (getUploadUrl + kicking
        // the upload, or the invoke) so locking/backgrounding right after send doesn't suspend
        // us mid-step. iOS grants ~30s; the background URLSession then carries the actual blob
        // PUT across full suspension/termination, and the resume-time flush drives the invoke.
        let bgTask = BackgroundTaskBox(name: "send-media-\(item.id.uuidString)")
        defer { bgTask.end() }

        // Upload phase: if the blob isn't up yet, hand the PUT to the background session and
        // return. Completion posts .mediaUploadCompleted → flush re-enters here with
        // uploadedMediaUrl set to run the invoke (which can't happen while suspended anyway).
        guard let mediaUrl = item.uploadedMediaUrl else {
            if await BackgroundUploadService.shared.hasInflightUpload(itemId: item.id) {
                // Already uploading in the background; its completion will drive the rest. Arm the
                // upload watchdog so a silently-broken completion→invoke chain can't spin forever.
                scheduleUploadWatchdog(for: item.id)
                return
            }
            do {
                let ext = (item.fileName as NSString).pathExtension
                let response = try await APIClient.shared.getUploadUrl(clubId: item.clubId, ext: ext.isEmpty ? nil : ext)
                guard let uploadUrl = URL(string: response.uploadUrl) else { return }
                BackgroundUploadService.shared.upload(
                    itemId: item.id, fileUrl: item.localFileUrl, uploadUrl: uploadUrl,
                    mediaUrl: response.mediaUrl, contentType: item.contentType)
                // Leave the bubble in .sending; it clears when the upload completes and the
                // invoke (below, on re-entry) lands the server echo. Arm the upload watchdog as a
                // safety net for that chain (#91) so a stuck send eventually becomes retryable.
                scheduleUploadWatchdog(for: item.id)
            } catch {
                MediaSendQueue.shared.incrementRetry(id: item.id)
                if let idx = messages.firstIndex(where: { $0.id == item.id }) {
                    messages[idx].sendState = .failed
                }
                if case ChatError.serverError(let msg) = error { errorMessage = msg }
            }
            return
        }

        // Send phase: the blob is uploaded; only posting the message remains. This POSTs over
        // the same background URLSession as the upload (#131) instead of a SignalR invoke, so
        // it isn't bounded by the ~30s BackgroundTaskBox window — a slow/large send can take as
        // long as it needs, backgrounded or not. Fire-and-forget: completion (success + the
        // confirmed Message, or failure) arrives via .mediaSendCompleted → handleSendCompleted,
        // which is the actual confirmation now (no SignalR echo wait needed).
        if await BackgroundUploadService.shared.hasInflightSend(itemId: item.id) {
            scheduleSendWatchdog(for: item.id)
            return
        }
        BackgroundUploadService.shared.sendMessage(
            itemId: item.id, bookId: item.bookId, type: Self.messageType(for: item.kind), mediaUrl: mediaUrl,
            durationSeconds: item.durationSeconds, clientId: item.id, parentMessageId: item.parentMessageId)
        if let idx = messages.firstIndex(where: { $0.id == item.id }) {
            messages[idx].sendState = .sending
        }
        scheduleSendWatchdog(for: item.id)
    }

    // Drive the send once a background upload finishes. On success the queue item now has
    // uploadedMediaUrl set, so re-entering sendMediaItem skips straight to posting the message;
    // on failure it re-fetches a fresh SAS and re-uploads (auto-retry up to the cap).
    private func handleUploadCompleted(_ itemId: UUID) async {
        guard let item = MediaSendQueue.shared.items.first(where: { $0.id == itemId }),
              item.bookId == book.id else { return }
        if let idx = messages.firstIndex(where: { $0.id == itemId }) {
            messages[idx].sendState = .sending
        }
        await sendMediaItem(item)
    }

    private static func messageType(for kind: MediaQueueKind) -> MessageType {
        switch kind {
        case .voice: return .voice
        case .photo: return .photo
        case .video: return .video
        }
    }

    // Reconcile a confirmed server message (from a REST send response, or a live SignalR
    // echo) with its optimistic bubble. Shared by both transports so "the message posted" is
    // handled identically regardless of which one delivered the confirmation first — a race
    // between them (e.g. another of this account's devices still has a live socket) is
    // resolved by the `messages.contains(where: { $0.id == message.id })` no-op guard below.
    @MainActor
    private func reconcileConfirmedMessage(_ message: Message) {
        guard message.clubId == book.clubId else { return }

        // Prefetch the audio so tapping play is instant by the time the user does.
        if message.type == .voice, let u = message.mediaUrl, let url = URL(string: u) {
            AudioCache.shared.prefetch(url)
        }

        // Already applied (the other transport got here first) — no-op.
        guard !messages.contains(where: { $0.id == message.id }) else { return }

        // Optimistic match by clientId — the server echoes back the clientId we sent for both
        // text and media. Replace the optimistic bubble in place. Using the id (not the body)
        // fixes identical consecutive text sends racing (#35).
        if message.senderId == TokenStore.shared.userId,
           let clientId = message.clientId,
           let idx = messages.firstIndex(where: { $0.id == clientId }) {
            let oldUrlString = messages[idx].mediaUrl
            messages[idx] = message
            pendingTextIds.remove(clientId)
            echoTimeoutTasks[clientId]?.cancel()
            echoTimeoutTasks[clientId] = nil
            if message.type != .text {
                // Media: confirmed delivery — clear the send queue + local file.
                MediaSendQueue.shared.remove(id: clientId)
                if let oldUrlString,
                   let oldUrl = URL(string: oldUrlString),
                   oldUrl.scheme == "file" {
                    MediaSendQueue.shared.scheduleCleanup(fileName: oldUrl.lastPathComponent)
                }
            }
            saveMessagesCache()
            return
        }

        messages.insert(message, at: 0)
        saveMessagesCache()
        // The read receipt's response carries this book's fresh unread count — an arriving
        // voice message raises it (unheard), non-voice nets to zero (read on arrival).
        Task { await ReceiptQueue.shared.markRead(bookId: book.id, messageId: message.id) }
    }

    // Completion of the background-session send POST kicked from sendMediaItem (#131). This
    // is the send confirmation now — no SignalR echo wait needed, since the REST response
    // itself proves the message reached the server (or tells us definitively why it didn't).
    @MainActor
    private func handleSendCompleted(itemId: UUID, success: Bool, message: Message?, errorMessage: String?) {
        guard success, let message else {
            MediaSendQueue.shared.incrementRetry(id: itemId)
            if let idx = messages.firstIndex(where: { $0.id == itemId }) {
                messages[idx].sendState = .failed
            }
            if let errorMessage { self.errorMessage = errorMessage }
            return
        }
        markOnline()
        reconcileConfirmedMessage(message)
    }

    // Preview text for the quoted-reply chip (mirrors the server's ParentPreviewText).
    private func replyPreview(for m: Message) -> String {
        if m.isDeleted { return "Deleted message" }
        switch m.type {
        case .text: return m.body ?? ""
        case .voice: return "🎤 Voice message"
        case .photo: return "📷 Photo"
        case .video: return "🎬 Video"
        case .unknown: return ""
        }
    }

    // Clear the offline banner whenever something proves we're online (a SignalR
    // receive, a successful send, etc.). The banner sticks until we see fresh
    // evidence of connectivity rather than reflecting some stale prior failure.
    private func markOnline() {
        if isOffline { isOffline = false }
    }

    // Paginate back to older messages. Fired by a sentinel view at the top of the
    // chat scroll view; idempotent under repeated calls (in-flight or terminal).
    func loadOlderMessages() async {
        guard !isLoadingOlderMessages, !reachedBeginning else { return }
        // Find the oldest confirmed message — skip optimistic entries whose sentAt
        // is "now" and would yield a useless query.
        let pendingMediaIds = Set(MediaSendQueue.shared.items.map { $0.id })
        let oldestConfirmed = messages.last(where: {
            !pendingTextIds.contains($0.id) && !pendingMediaIds.contains($0.id)
        })
        guard let before = oldestConfirmed?.sentAt else { return }

        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }
        do {
            let older = try await APIClient.shared.getMessages(bookId: book.id, before: before)
            markOnline()
            if older.isEmpty {
                reachedBeginning = true
                return
            }
            // Merge into messages, dedup by id (server might overlap on the boundary).
            var byId: [UUID: Message] = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
            for msg in older where byId[msg.id] == nil { byId[msg.id] = msg }
            messages = byId.values.sorted(by: { $0.sentAt > $1.sentAt })
            saveMessagesCache()
        } catch {
            // Silent — the sentinel will fire again on next scroll attempt.
        }
    }

    // Persist the current messages to disk cache, bounded to the most recent N
    // and filtered to only confirmed messages. Optimistic-only entries (text
    // waiting on echo, media still in the send queue) are excluded so a kill +
    // relaunch doesn't show ghost messages that never actually got delivered.
    private func saveMessagesCache() {
        let pendingMediaIds = Set(MediaSendQueue.shared.items.map { $0.id })
        let pending = pendingTextIds.union(pendingMediaIds)
        ChatCache.save(messages, bookId: book.id, excludingPending: pending)
    }

    // Send-phase safety net (#131): a media item hands its "post the message" call to a
    // background-URLSession POST (BackgroundUploadService.sendMessage), which has no time
    // limit but could still, in principle, have its completion callback silently dropped. If
    // that happens the bubble would spin in .sending forever. This flips a genuinely-stuck item
    // to .failed so the user can retry — but re-arms instead of failing while a send is still
    // actually in flight, so it can never false-fail a slow-but-healthy transfer.
    //
    // The watchdog is tracked + cancellable so backgrounding can tear it down: otherwise its
    // sleep would elapse against wall-clock while suspended and fire the instant we resume,
    // falsely failing a send that was simply waiting out a suspension (#70/#72). A fresh
    // send/re-send replaces any prior watchdog for the same item.
    private func scheduleSendWatchdog(for itemId: UUID, after seconds: TimeInterval = 90) {
        echoTimeoutTasks[itemId]?.cancel()
        echoTimeoutTasks[itemId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            // Still sending — give it more time rather than failing an in-progress POST.
            if await BackgroundUploadService.shared.hasInflightSend(itemId: itemId) {
                self.scheduleSendWatchdog(for: itemId, after: seconds)
                return
            }
            self.echoTimeoutTasks[itemId] = nil
            // Only fail an item that's still an un-confirmed optimistic send stuck in .sending
            // (a confirmed send would have reconciled the bubble's id via handleSendCompleted).
            guard MediaSendQueue.shared.items.contains(where: { $0.id == itemId }),
                  let idx = self.messages.firstIndex(where: { $0.id == itemId }),
                  self.messages[idx].sendState == .sending else { return }
            self.messages[idx].sendState = .failed
        }
    }

    // Upload-phase safety net (#91): a media send hands its blob to the background upload and
    // leaves the bubble .sending, relying on the upload-completion → send → confirmation chain
    // to finish it. If any link in that chain silently breaks (a missed completion callback, a
    // dropped connection on re-entry), the bubble would spin forever — which is the reported
    // "voice message stuck spinning, later messages went through". This flips a genuinely-stuck
    // item to .failed so the user can retry.
    //
    // Guarded so it can't false-fail a legitimately slow transfer: if the upload is still in
    // flight when it fires, it re-arms instead of failing. The send phase's own
    // scheduleSendWatchdog supersedes this (both key echoTimeoutTasks by id), and backgrounding
    // cancels it (cancelEchoTimeouts) so a suspended wall-clock can't fire it on resume.
    private func scheduleUploadWatchdog(for itemId: UUID, after seconds: TimeInterval = 90) {
        echoTimeoutTasks[itemId]?.cancel()
        echoTimeoutTasks[itemId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            // Still uploading — give it more time rather than failing an in-progress transfer.
            if await BackgroundUploadService.shared.hasInflightUpload(itemId: itemId) {
                self.scheduleUploadWatchdog(for: itemId, after: seconds)
                return
            }
            self.echoTimeoutTasks[itemId] = nil
            // Only fail an item that's still an un-echoed optimistic send stuck in .sending
            // (the echo would have removed it from the queue and reconciled the bubble's id).
            guard MediaSendQueue.shared.items.contains(where: { $0.id == itemId }),
                  let idx = self.messages.firstIndex(where: { $0.id == itemId }),
                  self.messages[idx].sendState == .sending else { return }
            self.messages[idx].sendState = .failed
        }
    }

    // Tear down all echo watchdogs (app backgrounding). The pending items stay queued with
    // their current state; the foreground re-flush re-sends and re-arms fresh watchdogs.
    private func cancelEchoTimeouts() {
        for task in echoTimeoutTasks.values { task.cancel() }
        echoTimeoutTasks.removeAll()
    }

    private var isFlushingMedia = false

    private func flushPendingMedia() async {
        // Guard against overlapping flushes (#37): foreground-resume and a SignalR reconnect can
        // both fire this, and without the guard each would resend the same queued items.
        guard !isFlushingMedia else { return }
        isFlushingMedia = true
        defer { isFlushingMedia = false }
        let pending = MediaSendQueue.shared.items.filter { $0.bookId == book.id }
        for item in pending {
            if let idx = messages.firstIndex(where: { $0.id == item.id }) {
                messages[idx].sendState = .sending
            }
            await sendMediaItem(item)
        }
    }

    func reportMessage(id: UUID) async {
        do {
            try await APIClient.shared.reportMessage(messageId: id)
        } catch {
            errorMessage = "Failed to submit report."
        }
    }

    func blockUser(senderId: UUID) async {
        blockedUserIds.insert(senderId)
        do {
            try await APIClient.shared.blockUser(userId: senderId)
        } catch {
            blockedUserIds.remove(senderId)
            errorMessage = "Failed to block user."
        }
    }

    func deleteMessage(id: UUID) async {
        do {
            try await ChatService.shared.deleteMessage(messageId: id)
        } catch {
            errorMessage = "Failed to delete message."
        }
    }

    // Edit an own text message. Optimistically update the bubble, then send; revert if
    // the server rejects. The server broadcast confirms it for everyone (incl. us).
    func editMessage(id: UUID, newBody: String) async {
        let trimmed = newBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = messages.firstIndex(where: { $0.id == id }),
              !trimmed.isEmpty, trimmed != messages[idx].body else { return }
        let previous = messages[idx].body
        messages[idx].body = trimmed
        do {
            try await ChatService.shared.editMessage(messageId: id, body: trimmed)
            saveMessagesCache()
        } catch {
            if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].body = previous }
            if case ChatError.serverError(let msg) = error { errorMessage = msg }
            else { errorMessage = "Failed to edit message." }
        }
    }

    func saveMessage(id: UUID) async {
        do {
            try await APIClient.shared.saveMessage(messageId: id)
            messageSaved = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            messageSaved = false
        } catch {
            errorMessage = "Failed to save message."
        }
    }

    func loadSavedMessages() async {
        isLoadingSaved = true
        defer { isLoadingSaved = false }
        do {
            savedMessages = try await APIClient.shared.getSavedMessages()
        } catch {
            errorMessage = "Failed to load saved messages."
        }
    }

    func unsaveSavedMessage(savedMessage: SavedMessage) async {
        savedMessages.removeAll { $0.id == savedMessage.id }
        do {
            try await APIClient.shared.unsaveMessage(messageId: savedMessage.messageId)
        } catch {
            savedMessages.append(savedMessage)
            errorMessage = "Failed to remove saved message."
        }
    }

    func forwardMessage(savedMessage: SavedMessage) async {
        showSavedMessages = false
        isUploading = true
        defer { isUploading = false }
        do {
            try await ChatService.shared.forwardMessage(bookId: book.id, messageId: savedMessage.messageId)
        } catch {
            errorMessage = "Failed to forward message."
        }
    }

    // Reflect an "Edit Book" save locally — only title/author change; keep the rest
    // (status, unread count, cover, metadata) as-is.
    func applyEdit(_ updated: Book) {
        book.title = updated.title
        book.author = updated.author
    }

    func setStatus(_ status: BookStatus) async {
        do {
            try await APIClient.shared.setBookStatus(bookId: book.id, status: status)
            book.status = status
            book.finishedAt = status == .past ? Date() : nil
        } catch {
            errorMessage = "Failed to update book status."
        }
    }

    func deleteBook() async throws {
        try await APIClient.shared.deleteBook(bookId: book.id)
    }

    func disconnect() {
        networkMonitor?.cancel()
        networkMonitor = nil
        cancelEchoTimeouts()
        stopLifecycleObservers()
        // Hand unread authority back to server truth (library reloads may now update this book).
        if UnreadStore.shared.activeBookIdIsCurrent(book.id) { UnreadStore.shared.setActiveBook(nil) }
        Task { await ChatService.shared.disconnect() }
    }

    // Re-flush pending media when the app returns to the foreground, and cancel echo
    // watchdogs when it leaves — so a send interrupted by locking/backgrounding the phone
    // finishes on resume instead of stranding (or falsely failing) the message (#70/#72).
    // Re-flush is safe to fire repeatedly: sendMediaItem skips items already in flight, and
    // the server's (SenderId, ClientId) idempotency makes any re-invoke duplicate-proof.
    private func startLifecycleObservers() {
        guard appActiveObserver == nil else { return }
        let center = NotificationCenter.default
        appActiveObserver = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.flushPendingMedia()
                await self?.flushPendingText()
            }
        }
        appBackgroundObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancelEchoTimeouts()
                // #146 — was discardRecording() (#75): iOS suspends capture seconds from now,
                // so the take can't continue either way, but silently throwing away whatever was
                // captured is the wrong default — finalize and send it instead, same as if the
                // user had deliberately released the mic. stopRecording() already no-ops below
                // 0.5s of audio, so an accidental instant background doesn't send a near-empty
                // clip.
                await self?.stopRecording()
            }
        }
        // Recording interrupted by a phone call / Siri / alarm. Only `.began` matters — once
        // interrupted, the audio session is gone and capture cannot resume, so `.ended` is still
        // ignored; the only choice was ever finalize-vs-discard, and #146 changed that choice
        // from discard (#75) to finalize-and-send, same reasoning as the backgrounding case above.
        audioInterruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in await self?.stopRecording() }
        }
        // A background blob upload finished — drive the send for that item (B).
        uploadCompletedObserver = center.addObserver(
            forName: .mediaUploadCompleted, object: nil, queue: .main
        ) { [weak self] note in
            guard let itemId = note.userInfo?["itemId"] as? UUID else { return }
            Task { @MainActor in await self?.handleUploadCompleted(itemId) }
        }
        // A background message-send POST finished (#131) — reconcile the bubble directly from
        // the response, no echo wait needed.
        sendCompletedObserver = center.addObserver(
            forName: .mediaSendCompleted, object: nil, queue: .main
        ) { [weak self] note in
            guard let itemId = note.userInfo?["itemId"] as? UUID else { return }
            let success = note.userInfo?["success"] as? Bool ?? false
            let message = note.userInfo?["message"] as? Message
            let errorMessage = note.userInfo?["errorMessage"] as? String
            Task { @MainActor in self?.handleSendCompleted(itemId: itemId, success: success, message: message, errorMessage: errorMessage) }
        }
    }

    private func stopLifecycleObservers() {
        if let o = appActiveObserver { NotificationCenter.default.removeObserver(o) }
        if let o = appBackgroundObserver { NotificationCenter.default.removeObserver(o) }
        if let o = uploadCompletedObserver { NotificationCenter.default.removeObserver(o) }
        if let o = sendCompletedObserver { NotificationCenter.default.removeObserver(o) }
        if let o = audioInterruptionObserver { NotificationCenter.default.removeObserver(o) }
        appActiveObserver = nil
        appBackgroundObserver = nil
        uploadCompletedObserver = nil
        sendCompletedObserver = nil
        audioInterruptionObserver = nil
    }

    private func startNetworkMonitorIfNeeded() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        let prevStatus = NetPathStatusBox()
        monitor.pathUpdateHandler = { [weak self] path in
            let wasOffline = prevStatus.value.map { $0 != .satisfied } ?? false
            prevStatus.value = path.status
            guard wasOffline, path.status == .satisfied else { return }
            Task { await self?.load() }
        }
        monitor.start(queue: DispatchQueue(label: "book-net-monitor"))
    }
}

/// Reference holder for the previous network status. NWPathMonitor serializes
/// its handler on a single queue, so unsynchronized access to `value` is safe;
/// the box lets the @Sendable handler mutate state without capturing a `var`.
private final class NetPathStatusBox: @unchecked Sendable {
    var value: NWPath.Status?
}
