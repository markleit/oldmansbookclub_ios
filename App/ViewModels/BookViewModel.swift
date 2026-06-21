import Foundation
import UIKit
import AVFoundation
import Network

@MainActor
final class BookViewModel: ObservableObject {
    @Published var book: Book
    @Published var messages: [Message] = []
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
    @Published var blockedUserIds: Set<UUID> = []
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

    var visibleMessages: [Message] {
        messages.filter { !blockedUserIds.contains($0.senderId) }
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

    private var cacheKey: String { "messages_\(book.id)" }

    // Optimistic text messages awaiting their server echo, tracked by clientId (the
    // server echoes it back). Keyed by id — not body — so identical consecutive sends
    // don't clobber each other (#35).
    private var pendingTextIds: Set<UUID> = []
    private var currentlySendingMedia: Set<UUID> = []
    private let audioRecorder = AudioRecorder()
    private var networkMonitor: NWPathMonitor?
    private var recordingStartTime: Date?
    private let maxAutoRetries = 5
    private let maxCachedMessages = 1000  // ~weeks of normal chat at modest disk cost

    init(book: Book) {
        self.book = book
    }

    func load() async {
        let hasCachedState: Bool
        if let cached = CacheService.shared.load([Message].self, key: cacheKey) {
            messages = cached
            hasCachedState = true
        } else {
            hasCachedState = false
        }
        isOffline = false
        isLoadingMessages = !hasCachedState
        reachedBeginning = false

        let bookId = book.id

        // Fire messages, blocked, and reads all in parallel — they're independent
        async let messagesFetch = APIClient.shared.getMessages(bookId: bookId)
        async let blockedFetch = APIClient.shared.fetchBlockedUserIds()
        async let readsFetch = APIClient.shared.getReads(bookId: bookId)

        do {
            let fetched = try await messagesFetch
            // Merge by id so previously-paginated older messages and unconfirmed
            // optimistic entries survive across refresh. Fresh fetch wins on
            // overlapping ids (server-side edits propagate).
            var byId: [UUID: Message] = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
            let myId = TokenStore.shared.userId
            for msg in fetched {
                // Reconcile a confirmed server message with its optimistic copy when the
                // live SignalR echo was missed (e.g. app backgrounded mid-send). The
                // optimistic entry's id equals our clientId; without this the server copy
                // (different id) would appear as a duplicate and the queue entry would stick.
                if let cid = msg.clientId, msg.senderId == myId, byId[cid] != nil {
                    byId.removeValue(forKey: cid)
                    clearPendingSend(clientId: cid)
                }
                byId[msg.id] = msg
            }
            messages = byId.values.sorted(by: { $0.sentAt > $1.sentAt })
            saveMessagesCache()
            prefetchRecentVoiceAudio()

            // Restore any media messages that were pending when the app was last closed
            restorePendingMediaBubbles()
        } catch is CancellationError {
            isLoadingMessages = false
            return
        } catch {
            if hasCachedState {
                isOffline = true
                // Keep any pending media items visible while offline
                restorePendingMediaBubbles()
            } else {
                errorMessage = "Failed to load discussion."
            }
        }
        isLoadingMessages = false
        startNetworkMonitorIfNeeded()

        guard !isOffline else { return }

        let latestId = messages.first?.id

        if let ids = try? await blockedFetch { blockedUserIds = Set(ids) }
        if let fetched = try? await readsFetch { reads = fetched }

        // markRead fires after messages resolved (needs latestId)
        if let id = latestId {
            try? await APIClient.shared.markRead(bookId: bookId, messageId: id)
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

            // Optimistic echo match by clientId — the server echoes back the clientId we
            // sent for both text and media. Replace the optimistic bubble in place. Using
            // the id (not the body) fixes identical consecutive text sends racing (#35).
            if message.senderId == TokenStore.shared.userId,
               let clientId = message.clientId,
               let idx = self.messages.firstIndex(where: { $0.id == clientId }) {
                let oldUrlString = self.messages[idx].mediaUrl
                self.messages[idx] = message
                self.pendingTextIds.remove(clientId)
                if message.type != .text {
                    // Media: confirmed delivery — clear the send queue + local file.
                    MediaSendQueue.shared.remove(id: clientId)
                    if let oldUrlString,
                       let oldUrl = URL(string: oldUrlString),
                       oldUrl.scheme == "file" {
                        MediaSendQueue.shared.scheduleCleanup(fileName: oldUrl.lastPathComponent)
                    }
                }
                self.saveMessagesCache()
                return
            }

            self.messages.insert(message, at: 0)
            self.saveMessagesCache()
            Task { try? await APIClient.shared.markRead(bookId: self.book.id, messageId: message.id) }
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
            guard let self, payload.bookId == self.book.id,
                  payload.userId != TokenStore.shared.userId else { return }
            self.applyHeardReceipt(payload)
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

        do {
            try await ChatService.shared.sendText(bookId: book.id, body: text, clientId: clientId, parentMessageId: reply?.id)
            markOnline()
        } catch let outer {
            // Server-side rejection (rate limit, validation) — don't retry, just surface it.
            if case ChatError.serverError(let msg) = outer {
                messages.removeAll { $0.id == clientId }
                pendingTextIds.remove(clientId)
                errorMessage = msg
                return
            }
            await ChatService.shared.disconnect()
            await ChatService.shared.connect(bookId: book.id)
            do {
                try await ChatService.shared.sendText(bookId: book.id, body: text, clientId: clientId)
                markOnline()
            } catch let inner {
                messages.removeAll { $0.id == clientId }
                pendingTextIds.remove(clientId)
                if case ChatError.serverError(let msg) = inner {
                    errorMessage = msg
                } else {
                    errorMessage = "Failed to send — connection lost. Please try again."
                }
            }
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

        // Enforce limits before queueing: max 5 min duration, max 100 MB file.
        let duration = (try? await AVURLAsset(url: videoUrl).load(.duration))?.seconds ?? 0
        if duration > 300 {
            pendingVideo = nil
            errorMessage = "Video is too long (max 5 minutes). Please trim it and try again."
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: videoUrl.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if fileSize > 100 * 1024 * 1024 {
            pendingVideo = nil
            errorMessage = "Video is too large (max 100 MB)."
            return
        }

        guard let persistentUrl = MediaSendQueue.shared.moveToQueue(from: videoUrl, extension: "mp4") else { return }
        pendingVideo = nil
        await enqueueAndSendMedia(
            kind: .video, contentType: "video/mp4", durationSeconds: nil,
            persistentUrl: persistentUrl, userId: userId
        )
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
        // "Mic is open" chirp (walkie-talkie style). Plays to completion before
        // capture starts so it precedes — and never bleeds into — the recording.
        await AudioCue.shared.playRecordStart()
        // Released during the chirp → stopRecording already flipped isRecording off;
        // abort without starting capture.
        guard isRecording else { return }
        do {
            try audioRecorder.start()
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
        pendingTextIds.remove(clientId)
    }

    func cancelMediaMessage(id: UUID) {
        if let item = MediaSendQueue.shared.items.first(where: { $0.id == id }) {
            MediaSendQueue.shared.cleanupFile(for: item)
            MediaSendQueue.shared.remove(id: id)
        }
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
        do {
            let mediaUrl: String
            if let uploaded = item.uploadedMediaUrl {
                // Upload succeeded on a previous attempt — only SignalR remains.
                mediaUrl = uploaded
            } else {
                let ext = (item.fileName as NSString).pathExtension
                let response = try await APIClient.shared.getUploadUrl(clubId: item.clubId, ext: ext.isEmpty ? nil : ext)
                guard let uploadUrl = URL(string: response.uploadUrl) else { return }
                try await APIClient.shared.uploadMediaFile(at: item.localFileUrl, to: uploadUrl, contentType: item.contentType)
                mediaUrl = response.mediaUrl
                MediaSendQueue.shared.markUploaded(id: item.id, mediaUrl: mediaUrl)
            }
            do {
                try await invokeHub(for: item, mediaUrl: mediaUrl)
            } catch let invokeErr {
                // Server-side rejection — don't reconnect+retry, it'll fail the same way.
                if case ChatError.serverError = invokeErr { throw invokeErr }
                // Stale-connection recovery — clientId idempotency prevents server-side duplicates.
                await ChatService.shared.disconnect()
                await ChatService.shared.connect(bookId: item.bookId)
                try? await Task.sleep(for: .milliseconds(500))
                try await invokeHub(for: item, mediaUrl: mediaUrl)
            }
            // Invoke succeeded — round trip proves we're online.
            markOnline()
            // Don't remove from queue here — wait for the server echo to confirm delivery.
            // Echo handler (onMessageReceived) removes the queue entry + schedules file
            // cleanup. If no echo arrives within the timeout, the bubble flips to .failed
            // and the queue entry stays so retry works.
            if let idx = messages.firstIndex(where: { $0.id == item.id }) {
                messages[idx].sendState = nil
            }
            scheduleEchoTimeout(for: item.id)
        } catch {
            MediaSendQueue.shared.incrementRetry(id: item.id)
            if let idx = messages.firstIndex(where: { $0.id == item.id }) {
                messages[idx].sendState = .failed
            }
            // Surface server-thrown error text (rate limit, etc.) since the failed bubble
            // alone doesn't explain why.
            if case ChatError.serverError(let msg) = error {
                errorMessage = msg
            }
        }
    }

    private func invokeHub(for item: MediaQueueItem, mediaUrl: String) async throws {
        switch item.kind {
        case .voice:
            try await ChatService.shared.sendVoice(
                bookId: item.bookId, mediaUrl: mediaUrl,
                durationSeconds: item.durationSeconds ?? 0, clientId: item.id, parentMessageId: item.parentMessageId)
        case .photo:
            try await ChatService.shared.sendPhoto(
                bookId: item.bookId, mediaUrl: mediaUrl, clientId: item.id, parentMessageId: item.parentMessageId)
        case .video:
            try await ChatService.shared.sendVideo(
                bookId: item.bookId, mediaUrl: mediaUrl, clientId: item.id, parentMessageId: item.parentMessageId)
        }
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
        let confirmed = messages.filter {
            !pendingTextIds.contains($0.id) && !pendingMediaIds.contains($0.id)
        }
        let bounded = Array(confirmed.prefix(maxCachedMessages))
        CacheService.shared.save(bounded, key: cacheKey)
    }

    // Safety net for silent SignalR failures: if invoke() returns success but the
    // server echo never arrives within the timeout, treat the send as failed so the
    // user knows (and can retry). The queue entry is preserved so retry works.
    private func scheduleEchoTimeout(for itemId: UUID, after seconds: TimeInterval = 15) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self else { return }
            // Echo would have replaced the optimistic message's id with the server's id;
            // if we still find the optimistic id, no echo arrived in time.
            guard let idx = self.messages.firstIndex(where: { $0.id == itemId }) else { return }
            // Only flip to failed if not already terminal — covers user-cancelled or
            // late-arriving echo edge cases.
            if self.messages[idx].sendState == nil {
                self.messages[idx].sendState = .failed
            }
        }
    }

    private func flushPendingMedia() async {
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
        Task { await ChatService.shared.disconnect() }
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
