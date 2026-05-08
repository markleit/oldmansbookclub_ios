import Foundation
import UIKit
import AVFoundation

@MainActor
final class BookViewModel: ObservableObject {
    @Published var book: Book
    @Published var messages: [Message] = []
    @Published var isLoadingMessages = false
    @Published var isOffline = false
    @Published var messageText = ""
    @Published var errorMessage: String?
    @Published var pendingImage: UIImage?
    @Published var isRecording = false
    @Published var isUploading = false

    private var cacheKey: String { "messages_\(book.id)" }

    private var pendingByBody: [String: UUID] = [:]
    private let audioRecorder = AudioRecorder()

    init(book: Book) {
        self.book = book
    }

    func load() async {
        if let cached = CacheService.shared.load([Message].self, key: cacheKey), !cached.isEmpty {
            messages = cached
        }
        isLoadingMessages = messages.isEmpty

        do {
            let fetched = try await APIClient.shared.getMessages(bookId: book.id)
            messages = fetched
            CacheService.shared.save(fetched, key: cacheKey)
            isOffline = false
        } catch {
            if messages.isEmpty {
                errorMessage = "Failed to load discussion."
            } else {
                isOffline = true
            }
        }
        isLoadingMessages = false

        guard !isOffline else { return }

        ChatService.shared.onMessageReceived = { [weak self] message in
            guard let self, message.clubId == self.book.clubId else { return }

            // If this is an echo of an optimistic message we inserted, replace it
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
        }
        await ChatService.shared.connect(bookId: book.id)
    }

    func sendMessage() async {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let userId = TokenStore.shared.userId else { return }
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
            errorMessage = "Failed to send message."
        }
    }

    func sendPhoto() async {
        guard let image = pendingImage,
              let data = image.resizedForUpload().jpegData(compressionQuality: 0.7),
              let clubId = TokenStore.shared.clubId else { return }
        pendingImage = nil
        isUploading = true
        defer { isUploading = false }
        do {
            let response = try await APIClient.shared.getUploadUrl(clubId: clubId)
            guard let uploadUrl = URL(string: response.uploadUrl) else { return }
            try await APIClient.shared.uploadMedia(data: data, to: uploadUrl, contentType: "image/jpeg")
            try await ChatService.shared.sendPhoto(bookId: book.id, mediaUrl: response.mediaUrl)
        } catch {
            errorMessage = "Failed to send photo."
        }
    }

    func toggleRecording() async {
        if isRecording {
            isRecording = false
            guard let (url, duration) = audioRecorder.stop(),
                  let data = try? Data(contentsOf: url),
                  let clubId = TokenStore.shared.clubId else { return }
            isUploading = true
            defer { isUploading = false }
            do {
                let response = try await APIClient.shared.getUploadUrl(clubId: clubId)
                guard let uploadUrl = URL(string: response.uploadUrl) else { return }
                try await APIClient.shared.uploadMedia(data: data, to: uploadUrl, contentType: "audio/mp4")
                try await ChatService.shared.sendVoice(bookId: book.id, mediaUrl: response.mediaUrl, durationSeconds: duration)
            } catch {
                errorMessage = "Failed to send voice message."
            }
        } else {
            let granted: Bool
            if #available(iOS 17.0, *) {
                granted = await AVAudioApplication.requestRecordPermission()
            } else {
                granted = await withCheckedContinuation { cont in
                    AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
                }
            }
            guard granted else {
                errorMessage = "Microphone access denied. Enable it in Settings."
                return
            }
            do {
                try audioRecorder.start()
                isRecording = true
            } catch {
                errorMessage = "Could not start recording."
            }
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

    func disconnect() async {
        await ChatService.shared.disconnect()
    }
}
