import Foundation
import Network

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var books: [Book] = []
    @Published var clubId: UUID? = TokenStore.shared.clubId
    @Published var clubName: String? = TokenStore.shared.clubName
    @Published var myClubs: [Club] = []
    @Published var isLoading = false
    @Published var isOffline = false
    @Published var errorMessage: String?
    @Published var imageRefreshToken = UUID()

    var currentReads: [Book] { books.filter { $0.clubId == clubId && $0.status == .current } }
    var bookList: [Book] { books.filter { $0.clubId == clubId && $0.status == .future } }
    var pastReads: [Book] { books.filter { $0.clubId == clubId && $0.status == .past } }

    private static let cacheKey = "cached_books"
    private static let decoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

    private var networkMonitor: NWPathMonitor?

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
        isOffline = false
        isLoading = books.isEmpty
        errorMessage = nil

        let clubs = (try? await APIClient.shared.getMyClubs()) ?? []
        myClubs = clubs
        if TokenStore.shared.clubId == nil || !clubs.contains(where: { $0.id == TokenStore.shared.clubId }) {
            let first = clubs.first
            TokenStore.shared.clubId = first?.id
            TokenStore.shared.clubName = first?.name
        }

        clubId = TokenStore.shared.clubId
        clubName = TokenStore.shared.clubName ?? myClubs.first(where: { $0.id == clubId })?.name

        guard clubId != nil else {
            isLoading = false
            return
        }

        do {
            let fetched = try await APIClient.shared.getMyBooks()
            books = fetched
            saveCache(fetched)
            imageRefreshToken = UUID()
        } catch {
            if books.isEmpty {
                errorMessage = "Unable to load books. Check your connection."
            } else {
                isOffline = true
            }
        }
        isLoading = false
        startNetworkMonitorIfNeeded()
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
        monitor.start(queue: DispatchQueue(label: "library-net-monitor"))
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

    func switchClub(_ club: Club) {
        TokenStore.shared.clubId = club.id
        TokenStore.shared.clubName = club.name
        clubId = club.id
        clubName = club.name
        books = []
        Task { await load() }
    }
}
