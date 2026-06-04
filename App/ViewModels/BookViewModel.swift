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
    private let audioRecorder = AudioRecorder()
    private var networkMonitor: NWPathMonitor?
    private var recordingStartTime: Date?

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

        guard !isOffline else { return }

        let latestId = messages.first?.id

        if let ids = try? await blockedFetch { blockedUserIds = Set(ids) }
        if let fetched = try? await readsFetch { reads = fetched }

        // markRead fires after messages resolved (needs latestId)
        if let id = latestId {
            try? await APIClient.shared.markRead(bookId: bookId, messageId: id)
        }

        ChatService.shared.onMessageReceived = { [weak self] message in
            guard let self, message.clubId == self.book.clubId else { return }

            if let body = message.body,
               message.senderId == TokenStore.shared.userId,
               let clientId = self.pendingByBody[body] {
                self.pendingByBody.removeValue(forKey: body)
                if let idx = self.messages.firstIndex(where: { $0.id == clientId }) {
                    self.messages[idx] = message
                }
                return
            }

            self.messages.insert(message, at: 0)
            Task { try? await APIClient.shared.markRead(bookId: self.book.id, messageId: message.id) }
        }

        ChatService.shared.onMessageDeleted = { [weak self] messageId in
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
        } catch ChatError.notConnected {
            await ChatService.shared.connect(bookId: book.id)
            do {
                try await ChatService.shared.sendText(bookId: book.id, body: text)
            } catch {
                messages.removeAll { $0.id == clientId }
                pendingByBody.removeValue(forKey: text)
                errorMessage = "Failed to send — connection lost. Please try again."
            }
        } catch {
            messages.removeAll { $0.id == clientId }
            pendingByBody.removeValue(forKey: text)
            errorMessage = "Failed to send message."
        }
    }

    func sendPhoto() async {
        guard let image = pendingImage,
              let data = image.resizedForUpload().jpegData(compressionQuality: 0.7) else { return }
        pendingImage = nil
        isUploading = true
        defer { isUploading = false }
        do {
            let response = try await APIClient.shared.getUploadUrl(clubId: book.clubId)
            guard let uploadUrl = URL(string: response.uploadUrl) else { return }
            try await APIClient.shared.uploadMedia(data: data, to: uploadUrl, contentType: "image/jpeg")
            try await ChatService.shared.sendPhoto(bookId: book.id, mediaUrl: response.mediaUrl)
        } catch {
            errorMessage = "Failed to send photo."
        }
    }

    func sendVideo() async {
        guard let videoUrl = pendingVideo else { return }
        pendingVideo = nil
        isUploading = true
        defer { isUploading = false }
        do {
            let response = try await APIClient.shared.getUploadUrl(clubId: book.clubId)
            guard let uploadUrl = URL(string: response.uploadUrl) else { return }
            try await APIClient.shared.uploadMediaFile(at: videoUrl, to: uploadUrl, contentType: "video/mp4")
            try await ChatService.shared.sendVideo(bookId: book.id, mediaUrl: response.mediaUrl)
        } catch {
            errorMessage = "Failed to send video."
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
        guard let (url, duration) = audioRecorder.stop() else { return }
        guard elapsed >= 0.5 else { return } // discard accidental taps
        guard let data = try? Data(contentsOf: url) else { return }
        isUploading = true
        defer { isUploading = false }
        do {
            let response = try await APIClient.shared.getUploadUrl(clubId: book.clubId)
            guard let uploadUrl = URL(string: response.uploadUrl) else { return }
            try await APIClient.shared.uploadMedia(data: data, to: uploadUrl, contentType: "audio/mp4")
            try await ChatService.shared.sendVoice(bookId: book.id, mediaUrl: response.mediaUrl, durationSeconds: duration)
        } catch {
            errorMessage = "Failed to send voice message."
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
