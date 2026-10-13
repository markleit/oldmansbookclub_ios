import Combine
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
    // #201 — up to 10 photos picked for one send (or one video in pendingVideo, never both).
    @Published var pendingImages: [UIImage] = []
    static let maxPendingPhotos = 10
    @Published var pendingVideo: URL? {
        didSet { if pendingVideo != oldValue { prepareVideo() } }
    }
    // #204 design v2 — the picked video is made ready (checked, compressed) in the composer, before
    // Send (VideoPreparation). `videoProgress` is non-nil while that's under way; Send waits for
    // `preparedVideo`.
    @Published private(set) var videoProgress: Double?
    @Published private(set) var preparedVideo: URL?
    private var preparedIsCopy = false
    private var preparing: Task<Void, Never>?
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
    @Published var toast: Toast?
    @Published var photosAccessDenied = false
    @Published var reads: [APIClient.ChatReadDto] = [] {
        didSet { recomputeReadFrontiers() }
    }
    // member userId -> sentAt of their last-seen message, for read receipts.
    private var readFrontierByUser: [UUID: Date] = [:]

    // #9: memoized — BookDetailView reads visibleMessages 20+ times per render, so recomputing
    // the filter on every access was pure waste. Now refreshed only when its inputs (messages /
    // blockedUserIds) change, via their didSet.
    @Published private(set) var visibleMessages: [Message] = []
    /// #204 PR 6 — someone else's message that landed above what you'd already seen (a late
    /// arrival, or a slow upload tapped earlier). The chat shows "↑ New message above" until it's
    /// seen. The oldest such message, so reading down from it covers the rest.
    @Published var newMessageAboveId: UUID?

    private func recomputeVisibleMessages() {
        // #204 — the chat shows the server's messages plus this chat's unsent ones, which belong
        // to the SendEngine (app-wide, on disk), not to this screen. Ordered by sentAt: the tap
        // time for a pending bubble, the server's clamped copy of it once confirmed — so a bubble
        // stays put when its confirmation swaps in.
        let confirmed = messages.filter { !blockedUserIds.contains($0.senderId) }
        visibleMessages = pendingBubbles.isEmpty ? confirmed
            : (confirmed + pendingBubbles).sorted { $0.sentAt > $1.sentAt }
    }

    /// This chat's unsent messages, as bubbles (from SendEngine.items).
    private var pendingBubbles: [Message] = [] {
        didSet { recomputeVisibleMessages() }
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

    // #204 — every send goes through the app-wide SendEngine; this screen only draws its items
    // for this book and applies its confirmations.
    private let engine: SendEngine
    private var engineSubscriptions: Set<AnyCancellable> = []
    // App-lifecycle observers: finalize a recording when we leave the foreground or a call
    // interrupts it. Registered once (see startLifecycleObservers).
    private var appBackgroundObserver: NSObjectProtocol?
    private var audioInterruptionObserver: NSObjectProtocol?
    private let audioRecorder = AudioRecorder()
    /// The take being recorded (#213): pauses through an interruption, resumes within 15 s.
    private var take: RecordingTake?
    private var networkMonitor: NWPathMonitor?
    private var recordingStartTime: Date?

    init(book: Book, engine: SendEngine = .shared) {
        self.book = book
        self.engine = engine
        let bookId = book.id
        engine.$items.combineLatest(engine.$isOffline)
            .receive(on: RunLoop.main)
            .sink { [weak self] items, _ in self?.refreshPendingBubbles(items.filter { $0.bookId == bookId }) }
            .store(in: &engineSubscriptions)
        engine.confirmations
            .filter { $0.bookId == bookId }
            .sink { [weak self] in self?.reconcileConfirmedMessage($0.message) }
            .store(in: &engineSubscriptions)
    }

    private func refreshPendingBubbles(_ items: [SendItem]) {
        guard let userId = TokenStore.shared.userId else { pendingBubbles = []; return }
        let name = TokenStore.shared.nickname ?? TokenStore.shared.displayName ?? ""
        pendingBubbles = items.map { item in
            let state: MessageSendState
            switch engine.displayState(of: item) {
            case .sending: state = .sending
            case .waiting: state = .waiting
            case .refused(let reason): state = .refused(reason)
            }
            return Message(
                id: item.id, clubId: item.clubId, senderId: userId, senderName: name,
                type: item.messageType,
                body: item.body,
                // The local file until it's confirmed — the bubble shows what you sent at once.
                mediaUrl: item.fileName.map { engine.files.fileURL($0).absoluteString } ?? item.mediaUrl,
                durationSeconds: item.durationSeconds, sentAt: item.sentAt,
                sendState: state, clientId: item.id,
                parentMessageId: item.parentMessageId, parentSenderName: item.parentSenderName,
                parentPreview: item.parentPreview)
        }
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
            // Unsent messages aren't in `messages` at all (#204): they're drawn from the SendEngine,
            // so replacing `messages` here can't hide one — the #189 "sent text vanishes" case.
            messages = cached
        }
        engine.chatOpened(clubId: book.clubId)
        isOffline = false
        isLoadingMessages = !hasCachedState
        reachedBeginning = false

        let bookId = book.id

        // Fire messages, blocked, and reads all in parallel — they're independent
        // With late arrivals: messages tapped before this page but received since (PR 6).
        async let messagesFetch = APIClient.shared.getMessages(bookId: bookId, includeLate: true)
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
            let previous = messages
            let merged = ChatCache.merge(existing: messages, incoming: fetched, myUserId: TokenStore.shared.userId)
            messages = merged.messages
            // A late arrival since this chat was last open lands above what you'd seen (PR 6).
            if let above = ChatOrder.arrivedAbove(previous: previous, current: messages,
                                                  me: TokenStore.shared.userId),
               let message = messages.first(where: { $0.id == above }) {
                noteArrivedAbove(message)
            }
            // A send the server has (it landed while the app was closed, or its response was lost)
            // is confirmed by the fetch itself — the engine drops it and stops retrying.
            for message in fetched where message.senderId == TokenStore.shared.userId {
                if let cid = message.clientId { engine.confirm(clientId: cid, message: message) }
            }
            saveMessagesCache()
            prefetchRecentVoiceAudio()
        } catch is CancellationError {
            isLoadingMessages = false
            return
        } catch {
            if hasCachedState {
                isOffline = true
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
        // The latest to arrive, not the newest by tap time: the server moves the read marker by
        // arrival, and a late arrival is older by tap time (PR 6).
        let latestId = ChatOrder.latestArrival(in: messages)?.id

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

            // Our own send echoed back: it's delivered, whichever transfer route is still out.
            if message.senderId == TokenStore.shared.userId, let cid = message.clientId,
               self.engine.items.contains(where: { $0.id == cid }) {
                self.engine.confirm(clientId: cid, message: message)
                return
            }
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
    }

    /// Send the composer's text. Fire and forget (#204): the engine has it on disk before this
    /// returns, and sends it whatever happens next.
    func sendMessage() async {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        guard TokenStore.shared.userId != nil else {
            errorMessage = "Session error — please sign out and back in."
            return
        }
        messageText = ""
        let reply = replyingTo
        replyingTo = nil
        engine.enqueueText(bookId: book.id, clubId: book.clubId, body: text, replyTo: reply)
    }

    /// "Send now" on a waiting message.
    func sendNow(id: UUID) {
        engine.sendNow(id)
    }

    /// Delete an unsent message (waiting or refused).
    func deleteUnsent(id: UUID) {
        engine.delete(id)
    }

    // #201 — send the picked photos (1–10) as one batch: any typed text first as the caption
    // (like the share sheet), then each photo as its own message, in the order they were picked.
    // Everything is queued — bubbles, durable entries, send-order seqs — before any network work
    // starts, so a force-quit mid-batch can't drop the later photos, and the pump posts them in
    // exactly this order however their uploads happen to finish.
    func sendPhotos() async {
        let images = pendingImages
        guard !images.isEmpty, TokenStore.shared.userId != nil else { return }
        pendingImages = []   // consumed before any await, so a double-tap can't send twice
        let reply = replyingTo
        replyingTo = nil
        // The caption goes first: its tap time is earlier, and tap time orders the chat (#204).
        let caption = messageText.trimmingCharacters(in: .whitespaces)
        if !caption.isEmpty {
            messageText = ""
            engine.enqueueText(bookId: book.id, clubId: book.clubId, body: caption, replyTo: reply)
        }

        // Resize + encode off the main actor: ten full-size photos would otherwise hitch the UI.
        let encoded: [Data] = await Task.detached(priority: .userInitiated) {
            images.compactMap(PhotoUpload.jpeg)
        }.value
        if encoded.count < images.count {
            errorMessage = "\(images.count - encoded.count) photo(s) couldn't be prepared and weren't sent."
        }
        // Without a caption, the first photo carries the reply (as before); never every photo.
        var replyForNext = caption.isEmpty ? reply : nil
        for data in encoded {
            do {
                let name = try engine.files.importData(data, extension: "jpg")
                engine.enqueueMedia(.photo, bookId: book.id, clubId: book.clubId, fileName: name,
                                    contentType: "image/jpeg", durationSeconds: nil, replyTo: replyForNext)
                replyForNext = nil
            } catch {
                errorMessage = "Your phone's storage is full, so a photo couldn't be queued."   // D4
            }
        }
    }

    func sendVideo() async {
        guard let videoUrl = pendingVideo, let ready = preparedVideo, TokenStore.shared.userId != nil else { return }
        // Consume the pending video up front: a second tap must not send it again (observed on
        // device before: two videos, distinct client ids, ~9 s apart). The prepared file is taken
        // first, so clearing the composer doesn't delete it.
        let isCopy = preparedIsCopy
        preparedVideo = nil
        pendingVideo = nil

        // Ready means checked and compressed (VideoPreparation): queued now, it's complete — the
        // engine hands it to iOS at once.
        guard let fileName = try? engine.files.importFile(at: ready, extension: "mp4", move: isCopy) else {
            // Couldn't stage the file (disk full) — hand the video back so Send stays live.
            pendingVideo = videoUrl
            errorMessage = "Your phone's storage is full, so the video couldn't be queued."
            return
        }
        let reply = replyingTo
        replyingTo = nil
        engine.enqueueMedia(.video, bookId: book.id, clubId: book.clubId, fileName: fileName,
                            contentType: "video/mp4", durationSeconds: nil, replyTo: reply)
    }

    /// Starts making the picked video ready (or clears what was made for one no longer picked).
    /// Interrupted — the app left the foreground — it starts again when the app's back.
    private func prepareVideo() {
        preparing?.cancel()
        preparing = nil
        if let old = preparedVideo, preparedIsCopy { try? FileManager.default.removeItem(at: old) }
        preparedVideo = nil
        videoProgress = nil
        guard let source = pendingVideo else { return }
        videoProgress = 0
        preparing = Task { [weak self] in
            let outcome = await VideoPreparation.prepare(source) { fraction in
                Task { @MainActor [weak self] in
                    if self?.pendingVideo == source, self?.videoProgress != nil { self?.videoProgress = fraction }
                }
            }
            guard let self else { return }
            guard !Task.isCancelled, self.pendingVideo == source else {
                if case .ready(let url, true) = outcome { try? FileManager.default.removeItem(at: url) }
                return
            }
            self.preparing = nil
            switch outcome {
            case .ready(let url, let compressed):
                self.preparedVideo = url
                self.preparedIsCopy = compressed
                self.videoProgress = nil
            case .refused(let reason):
                self.errorMessage = reason
                self.pendingVideo = nil
            case .interrupted:
                self.preparing = Task { [weak self] in
                    for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) { break }
                    guard let self, !Task.isCancelled, self.pendingVideo == source else { return }
                    self.prepareVideo()
                }
            }
        }
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
            take = RecordingTake(
                recorder: audioRecorder, now: { Date() },
                onLost: { [weak self] in
                    self?.errorMessage = "Your voice message couldn't be saved. Please record it again."
                },
                onFinished: { [weak self] file, _ in self?.takeFinished(file) })
            startRecordingTypingPings()   // broadcast "is recording audio…"
            // Let playback call sites finalize-and-send this take instead of fighting the
            // recorder for AVAudioSession (#160).
            AudioRecorder.forceStopForPlayback = { [weak self] in self?.finalizeRecording(.playback) }
        } catch {
            isRecording = false
            errorMessage = "Could not start recording."
        }
    }

    func stopRecording(_ reason: RecordingEnd = .released) async {
        _ = finalizeRecording(reason)
    }

    // Body of stopRecording(), extracted so AudioRecorder.forceStopForPlayback can call it
    // synchronously (playback call sites need the recorder already torn down before they touch
    // AVAudioSession themselves — see #160). The take decides what's kept and logs why it ended
    // (#213); `takeFinished` does the rest, whoever ended it.
    @discardableResult
    private func finalizeRecording(_ reason: RecordingEnd = .released) -> Bool {
        guard isRecording else { return false }
        guard let take else {
            // Released during the start chirp: startRecording sees this and doesn't start.
            isRecording = false
            return false
        }
        return take.finish(reason)
    }

    /// A take ended — released, or ended for it (an interruption over 15 s, leaving the chat,
    /// the background, playback). `file` is nil when it was too short to keep.
    private func takeFinished(_ file: (url: URL, duration: Int)?) {
        take = nil
        isRecording = false
        stopRecordingTypingPings()
        recordingStartTime = nil
        AudioRecorder.forceStopForPlayback = nil
        // "Mic closed" chirp — capture has ended, so it won't be in the recording.
        // Plays on close regardless of whether the take is kept or discarded.
        AudioCue.shared.playRecordStop()
        guard let (tempUrl, duration) = file, TokenStore.shared.userId != nil else { return }
        guard let fileName = try? engine.files.importFile(at: tempUrl, extension: "m4a") else {
            // Was silent: the take was simply lost (D4, found 2026-10-11).
            errorMessage = "Your phone's storage is full, so the voice message couldn't be queued."
            return
        }
        let reply = replyingTo
        replyingTo = nil
        engine.enqueueMedia(.voice, bookId: book.id, clubId: book.clubId, fileName: fileName,
                            contentType: "audio/mp4", durationSeconds: duration, replyTo: reply)
    }

    /// A call (answered or declined), Siri, an alarm or another app's audio took the microphone
    /// (#213): the take ends and what was recorded is sent — the same as every other way a take
    /// ends — with a note, since the user didn't stop it. To carry on, they record again.
    private func recordingInterrupted() {
        guard finalizeRecording(.interrupted) else { return }
        toast = Toast(text: "Voice message sent — record again to carry on", systemImage: "mic.fill")
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
        AudioRecorder.forceStopForPlayback = nil
        audioRecorder.discard()
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

        // The rules themselves live in SendReconciler so they can be unit-tested without a view
        // model or a network stack; what remains here is applying the decision.
        switch SendReconciler.outcome(for: message, in: messages,
                                      myUserId: TokenStore.shared.userId, bookClubId: book.clubId) {
        case .ignoreWrongClub, .ignoreAlreadyApplied:
            return

        case .replaceOptimistic:
            // #204 — unsent bubbles are no longer kept in `messages` (they're the SendEngine's),
            // so there's nothing to replace: our own confirmed send simply joins the list — at its
            // tap time (PR 6): a video tapped before a voice message but confirmed after it stays
            // above it, where its pending bubble was.
            messages.insert(message, at: ChatOrder.insertionIndex(of: message, in: messages))
            saveMessagesCache()

        case .insert:
            // At its tap time, not at the bottom (PR 6). Above the newest — it was tapped earlier
            // than something already here — means it's out of sight: "↑ New message above".
            let index = ChatOrder.insertionIndex(of: message, in: messages)
            messages.insert(message, at: index)
            if index > 0, message.senderId != TokenStore.shared.userId { noteArrivedAbove(message) }
            saveMessagesCache()
            // The read receipt's response carries this book's fresh unread count — an arriving
            // voice message raises it (unheard), non-voice nets to zero (read on arrival).
            Task { await ReceiptQueue.shared.markRead(bookId: book.id, messageId: message.id) }
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
        // `messages` holds only confirmed messages (#204), so the last is the oldest the server has.
        guard let before = messages.last?.sentAt else { return }

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
            messages = ChatOrder.sorted(byId.values)
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
        // Only confirmed messages are in `messages`; unsent ones live in the SendEngine's outbox.
        ChatCache.save(messages, bookId: book.id, excludingPending: [])
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
            toast = Toast(text: "Message saved", systemImage: "bookmark.fill")
        } catch {
            errorMessage = "Failed to save message."
        }
    }

    /// Keeps the oldest of the messages that arrived above the newest, for the "↑" chip.
    private func noteArrivedAbove(_ message: Message) {
        if let current = newMessageAboveId, let shown = messages.first(where: { $0.id == current }),
           ChatOrder.isNewer(message, than: shown) { return }
        newMessageAboveId = message.id
    }

    // #201 — the photo viewer's pages: every loaded, undeleted photo in this chat, oldest first
    // (visibleMessages is newest-first), so swiping left moves forward in time as in Photos.
    func photoGallery() -> [URL] {
        visibleMessages.reversed().compactMap { message in
            guard message.type == .photo, !message.isDeleted, let urlStr = message.mediaUrl else { return nil }
            return URL(string: urlStr)
        }
    }

    // #193 — long-press "Save to Photos" on a photo/video message.
    func saveToPhotos(_ kind: PhotoLibrarySaver.Kind, from url: URL) async {
        do {
            try await PhotoLibrarySaver.save(kind, from: url)
            toast = Toast(text: "Saved to Photos", systemImage: "checkmark.circle.fill")
        } catch PhotoLibrarySaver.SaveError.accessDenied {
            photosAccessDenied = true
        } catch {
            errorMessage = error.localizedDescription
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

    // #192 — forward a saved message to the chat the user picked (any book in their clubs; the
    // server checks membership). Saved Messages stays open and reports the outcome itself.
    /// #204 PR 9 — a forward is sent like any message: queued at once with a client id, retried
    /// until it's through, shown in the destination chat as sending. (It was a one-shot SignalR
    /// call: no network, and it failed with an alert.) A refusal shows red in that chat.
    func forwardMessage(savedMessage: SavedMessage, to book: Book) {
        engine.enqueueForward(bookId: book.id, clubId: book.clubId, messageId: savedMessage.messageId)
    }

    // Reflect an "Edit Book" save locally — title, author and cover; keep the rest
    // (status, unread count, metadata) as-is.
    func applyEdit(_ updated: Book) {
        book.title = updated.title
        book.author = updated.author
        book.coverBlobUrl = updated.coverBlobUrl
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
        // Leaving the chat mid-recording sends the take — it used to be lost (#213).
        finalizeRecording(.leftChat)
        preparing?.cancel()   // a picked video not sent is dropped with the composer
        networkMonitor?.cancel()
        networkMonitor = nil
        stopLifecycleObservers()
        // Hand unread authority back to server truth (library reloads may now update this book).
        if UnreadStore.shared.activeBookIdIsCurrent(book.id) { UnreadStore.shared.setActiveBook(nil) }
        Task { await ChatService.shared.disconnect() }
    }

    // Finalize an in-progress recording when the app leaves the foreground or a call interrupts
    // it. (Sending itself — retries, foreground and network-back triggers — is the SendEngine's,
    // app-wide, since #204; nothing here depends on this chat being open.)
    private func startLifecycleObservers() {
        guard appBackgroundObserver == nil else { return }
        let center = NotificationCenter.default
        appBackgroundObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // finalizeRecording() (via stopRecording()) does synchronous AVAudioSession
            // teardown, which can briefly block on route renegotiation (Bluetooth/CarPlay) —
            // exactly the kind of work that has to declare itself to iOS during backgrounding,
            // or risk a "failed to terminate" watchdog kill. beginBackgroundTask grants a real
            // grace period for it instead of racing the implicit one.
            var bgTask = UIBackgroundTaskIdentifier.invalid
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "finalize-recording-on-background") {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
            Task { @MainActor in
                // #146 — was discardRecording() (#75): iOS suspends capture seconds from now,
                // so the take can't continue either way, but silently throwing away whatever was
                // captured is the wrong default — finalize and send it instead, same as if the
                // user had deliberately released the mic. stopRecording() already no-ops below
                // 0.5s of audio, so an accidental instant background doesn't send a near-empty
                // clip.
                await self?.stopRecording(.background)
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }
        }
        // Recording interrupted by a call, Siri, an alarm or another app's audio (#213): the take
        // ends and is sent (recordingInterrupted). Nothing happens when the interruption ends —
        // resuming into the same message was tried and captured nothing on a device (2.2 (8)).
        audioInterruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            guard type == .began else { return }
            Task { @MainActor in self?.recordingInterrupted() }
        }
    }

    private func stopLifecycleObservers() {
        if let o = appBackgroundObserver { NotificationCenter.default.removeObserver(o) }
        if let o = audioInterruptionObserver { NotificationCenter.default.removeObserver(o) }
        appBackgroundObserver = nil
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
            // Refresh what others sent while we were offline. Our own unsent messages are the
            // SendEngine's: it hears "network back" app-wide (#204) and sends them from any screen.
            Task { @MainActor in await self?.load() }
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
