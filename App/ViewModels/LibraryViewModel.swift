import Foundation

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var books: [Book] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    var currentRead: Book? { books.first { $0.isCurrentRead } }
    var bookList: [Book] { books.filter { $0.isCurrentRead }.dropFirst().map { $0 } }
    var pastReads: [Book] { books.filter { !$0.isCurrentRead } }

    private static let cacheKey = "cached_books"
    private static let decoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? Self.decoder.decode([Book].self, from: data) else { return }
        books = cached
    }

    private func saveCache(_ books: [Book]) {
        guard let data = try? Self.encoder.encode(books) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    func load() async {
        loadCache()
        isLoading = books.isEmpty
        errorMessage = nil

        if TokenStore.shared.clubId == nil {
            let clubs = (try? await APIClient.shared.getMyClubs()) ?? []
            TokenStore.shared.clubId = clubs.first?.id
        }

        guard TokenStore.shared.clubId != nil else {
            isLoading = false
            return
        }

        do {
            let fetched = try await APIClient.shared.getMyBooks()
            books = fetched
            saveCache(fetched)
        } catch {
            if books.isEmpty {
                errorMessage = "Error: \(error)"
            }
        }
        isLoading = false
    }

    func bookCreated(_ book: Book) {
        books.insert(book, at: 0)
        saveCache(books)
    }

    func bookDeleted(_ book: Book) {
        books.removeAll { $0.id == book.id }
        saveCache(books)
    }

    func finishBook(_ book: Book) async {
        do {
            try await APIClient.shared.finishBook(bookId: book.id)
            if let idx = books.firstIndex(where: { $0.id == book.id }) {
                books[idx].finishedAt = Date()
                saveCache(books)
            }
        } catch {
            errorMessage = "Failed to mark book as finished."
        }
    }
}
