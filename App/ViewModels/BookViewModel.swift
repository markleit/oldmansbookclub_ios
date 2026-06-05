import Foundation
import UIKit
import AVFoundation
import Network

@MainActor
final class BookViewModel: ObservableObject {
    @Published var book: Book
    @Published var messages: [Message] = []
    @Published var isLoadingMessages = false
    @Published var isOffline = false
    @Published var messageText = ""
    @Published var errorMessage: String?
    @Published var showMicDeniedAlert = false
    @Published var blockedUserIds: Set<UUID> = []
    @Published var pendingImage: UIImage?
    @Published var pendingVideo: URL?
    @Published var isRecording = false
    @Published var isUploading = false
    @Published var showSavedMessages = false
    @Published var savedMessages: [SavedMessage] = []
    @Published var isLoadingSaved = false
    @Published var messageSaved = false
    @Published var reads: [APIClient.ChatReadDto] = []

    var visibleMessages: [Message] {
        messages.filter { !blockedUserIds.contains($0.senderId) }
    }

    private var cacheKey: String { "messages_\(book.id)" }

    private var pendingByBody: [String: UUID] = [:]
    private var currentlySendingMedia: Set<UUID> = []
    private let audioRecorder = AudioRecorder()
    private var networkMonitor: NWPathMonitor?
    private var recordingStartTime: Date?
    private let maxAutoRetries = 5

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

        let bookId = book.id

        // Fire messages, blocked, and reads all in parallel — they're independent
        async let messagesFetch = APIClient.shared.getMessages(bookId: bookId)
        async let blockedFetch = APIClient.shared.fetchBlockedUserIds()
        async let readsFetch = APIClient.shared.getReads(bookId: bookId)

        do {
            let fetched = try await messagesFetch
            let pendingIds = Set(pendingByBody.values)
            let surviving = messages.filter { pendingIds.contains($0.id) }
            messages = fetched
            for msg in surviving where !messages.contains(where: { $0.id == msg.id }) {
                messages.insert(msg, at: 0)
            }
            CacheService.shared.save(fetched, key: cacheKey)

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

            // Drop SignalR replays on auto-reconnect (same server ID already in list)
            guard !self.messages.contains(where: { $0.id == message.id }) else { return }

            // Text deduplication: match outgoing optimistic message by body
            if let body = message.body,
               message.senderId == TokenStore.shared.userId,
               let clientId = self.pendingByBody[body] {
                self.pendingByBody.removeValue(forKey: body)
                if let idx = self.messages.firstIndex(where: { $0.id == clientId }) {
                    self.messages[idx] = message
                }
                return
            }

            // Media deduplication (voice/photo/video): server echoes back clientId = optimistic Message.id.
            // Echo is the confirmed-delivery signal — remove the queue entry, replace the
            // optimistic bubble, and schedule cleanup of the local file.
            if (message.type == .voice || message.type == .photo || message.type == .video),
               message.senderId == TokenStore.shared.userId,
               let clientId = message.clientId,
               let idx = self.messages.firstIndex(where: { $0.id == clientId }) {
                let oldUrlString = self.messages[idx].mediaUrl
                self.messages[idx] = message
                MediaSendQueue.shared.remove(id: clientId)
                if let oldUrlString,
                   let oldUrl = URL(string: oldUrlString),
                   oldUrl.scheme == "file" {
                    MediaSendQueue.shared.scheduleCleanup(fileName: oldUrl.lastPathComponent)
                }
                return
            }

            self.messages.insert(message, at: 0)
            Task { try? await APIClient.shared.markRead(bookId: self.book.id, messageId: message.id) }
        }

        await ChatService.shared.setOnMessageDeleted { [weak self] messageId in
            guard let self else { return }
            if let idx = self.messages.firstIndex(where: { $0.id == messageId }) {
                self.messages[idx].isDeleted = true
                self.messages[idx].body = nil
                self.messages[idx].mediaUrl = nil
                self.messages[idx].durationSeconds = nil
                CacheService.shared.save(self.messages, key: self.cacheKey)
            }
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
                senderName: TokenStore.shared.displayName ?? "",
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

        let clientId = UUID()
        let optimistic = Message(
            id: clientId,
            clubId: book.clubId,
            senderId: userId,
            senderName: TokenStore.shared.displayName ?? "",
            type: .text,
            body: text,
            mediaUrl: nil,
            durationSeconds: nil,
            sentAt: Date()
        )
        messages.insert(optimistic, at: 0)
        pendingByBody[text] = clientId

        do {
            try await ChatService.shared.sendText(bookId: book.id, body: text)
        } catch {
            await ChatService.shared.disconnect()
            await ChatService.shared.connect(bookId: book.id)
            do {
                try await ChatService.shared.sendText(bookId: book.id, body: text)
            } catch {
                messages.removeAll { $0.id == clientId }
                pendingByBody.removeValue(forKey: text)
                errorMessage = "Failed to send — connection lost. Please try again."
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
        guard let videoUrl = pendingVideo,
              let userId = TokenStore.shared.userId,
              let persistentUrl = MediaSendQueue.shared.moveToQueue(from: videoUrl, extension: "mp4")
        else { return }
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
            senderName: TokenStore.shared.displayName ?? "",
            type: messageType,
            mediaUrl: persistentUrl.absoluteString,
            durationSeconds: durationSeconds,
            sentAt: Date(),
            sendState: .sending,
            clientId: localId
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
            retryCount: 0
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
        do {
            try audioRecorder.start()
            isRecording = true
            recordingStartTime = Date()
        } catch {
            errorMessage = "Could not start recording."
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        isRecording = false
        let elapsed = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartTime = nil
        guard let (tempUrl, duration) = audioRecorder.stop() else { return }
        guard elapsed >= 0.5 else { return }
        guard let persistentUrl = MediaSendQueue.shared.moveToQueue(from: tempUrl, extension: "m4a"),
              let userId = TokenStore.shared.userId else { return }

        await enqueueAndSendMedia(
            kind: .voice, contentType: "audio/mp4", durationSeconds: duration,
            persistentUrl: persistentUrl, userId: userId
        )
    }

    func retryMediaMessage(id: UUID) async {
        guard let item = MediaSendQueue.shared.items.first(where: { $0.id == id }) else { return }
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].sendState = .sending
        }
        await sendMediaItem(item)
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
            } catch {
                // Stale-connection recovery — clientId idempotency prevents server-side duplicates.
                await ChatService.shared.disconnect()
                await ChatService.shared.connect(bookId: item.bookId)
                try? await Task.sleep(for: .milliseconds(500))
                try await invokeHub(for: item, mediaUrl: mediaUrl)
            }
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
        }
    }

    private func invokeHub(for item: MediaQueueItem, mediaUrl: String) async throws {
        switch item.kind {
        case .voice:
            try await ChatService.shared.sendVoice(
                bookId: item.bookId, mediaUrl: mediaUrl,
                durationSeconds: item.durationSeconds ?? 0, clientId: item.id)
        case .photo:
            try await ChatService.shared.sendPhoto(
                bookId: item.bookId, mediaUrl: mediaUrl, clientId: item.id)
        case .video:
            try await ChatService.shared.sendVideo(
                bookId: item.bookId, mediaUrl: mediaUrl, clientId: item.id)
        }
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
        var prevStatus: NWPath.Status?
        monitor.pathUpdateHandler = { [weak self] path in
            let wasOffline = prevStatus.map { $0 != .satisfied } ?? false
            prevStatus = path.status
            guard wasOffline, path.status == .satisfied else { return }
            Task { await self?.load() }
        }
        monitor.start(queue: DispatchQueue(label: "book-net-monitor"))
    }
}
