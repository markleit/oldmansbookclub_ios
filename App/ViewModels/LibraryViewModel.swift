import Foundation

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var books: [Book] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    var currentRead: Book? { books.first { $0.isCurrentRead } }
    var pastReads: [Book] { books.filter { !$0.isCurrentRead } }

    func load() async {
        // Ensure we have a clubId cached
        if TokenStore.shared.clubId == nil {
            do {
                let clubs = try await APIClient.shared.getMyClubs()
                TokenStore.shared.clubId = clubs.first?.id
            } catch {
                errorMessage = "Failed to load club."
                return
            }
        }

        isLoading = true
        errorMessage = nil
        do {
            books = try await APIClient.shared.getMyBooks()
        } catch {
            errorMessage = "Failed to load books."
        }
        isLoading = false
    }

    func bookCreated(_ book: Book) {
        books.insert(book, at: 0)
    }

    func finishBook(_ book: Book) async {
        do {
            try await APIClient.shared.finishBook(bookId: book.id)
            if let idx = books.firstIndex(where: { $0.id == book.id }) {
                books[idx].finishedAt = Date()
            }
        } catch {
            errorMessage = "Failed to mark book as finished."
        }
    }
}
