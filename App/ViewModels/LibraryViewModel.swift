import Foundation

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var books: [Book] = []
    @Published var clubId: UUID? = TokenStore.shared.clubId
    @Published var isLoading = false
    @Published var errorMessage: String?

    var currentReads: [Book] { books.filter { $0.status == .current } }
    var bookList: [Book] { books.filter { $0.status == .future } }
    var pastReads: [Book] { books.filter { $0.status == .past } }

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

        clubId = TokenStore.shared.clubId

        guard clubId != nil else {
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

    func bookStatusChanged(_ book: Book, status: BookStatus) {
        if let idx = books.firstIndex(where: { $0.id == book.id }) {
            books[idx].status = status
            books[idx].finishedAt = status == .past ? Date() : nil
            saveCache(books)
        }
    }
}
