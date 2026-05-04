import Foundation

@MainActor
final class BookViewModel: ObservableObject {
    @Published var book: Book
    @Published var messages: [Message] = []
    @Published var isLoadingMessages = false
    @Published var messageText = ""
    @Published var errorMessage: String?

    // Tracks optimistically-inserted messages awaiting server echo: body → clientId
    private var pendingByBody: [String: UUID] = [:]

    init(book: Book) {
        self.book = book
    }

    func load() async {
        isLoadingMessages = true
        do {
            messages = try await APIClient.shared.getMessages(bookId: book.id)
        } catch {
            errorMessage = "Failed to load discussion."
        }
        isLoadingMessages = false

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

        await ChatService.shared.sendText(bookId: book.id, body: text)
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
