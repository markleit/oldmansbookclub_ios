import Foundation

@MainActor
final class BookViewModel: ObservableObject {
    @Published var book: Book
    @Published var messages: [Message] = []
    @Published var isLoadingMessages = false
    @Published var messageText = ""
    @Published var errorMessage: String?

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
            guard message.clubId == self?.book.clubId else { return }
            self?.messages.insert(message, at: 0)
        }
        await ChatService.shared.connect(bookId: book.id)
    }

    func sendMessage() async {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        messageText = ""
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
