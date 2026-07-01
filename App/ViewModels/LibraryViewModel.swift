import Foundation
import Network
import UserNotifications

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

    // Foreground/appear fire load() often (every scenePhase == .active, tab switches).
    // Skip a network refetch if we just did one, so quick app-switches don't churn the
    // list. User-driven loads (pull-to-refresh, retry, club switch, reconnect) pass force.
    private var lastLoadedAt: Date?
    private let minReloadInterval: TimeInterval = 30

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cached = try? Self.decoder.decode([Book].self, from: data) else { return }
        books = cached
    }

    private func saveCache(_ books: [Book]) {
        guard let data = try? Self.encoder.encode(books) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    func load(force: Bool = false) async {
        if !force, let last = lastLoadedAt, Date().timeIntervalSince(last) < minReloadInterval {
            return
        }
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
            let coversBefore = books.map { "\($0.id)|\($0.coverBlobUrl ?? "")" }
            let fetched = try await APIClient.shared.getMyBooks()
            books = fetched
            saveCache(fetched)
            lastLoadedAt = Date()
            // Only bust cover-image caches when a cover actually changed — bumping the
            // token unconditionally re-renders every cover on each foreground (the visible
            // "flicker"), even when nothing changed.
            let coversAfter = fetched.map { "\($0.id)|\($0.coverBlobUrl ?? "")" }
            if coversBefore != coversAfter { imageRefreshToken = UUID() }
            // Keep the app icon badge in sync with total unread on every load
            // (initial, pull-to-refresh, foreground). Pushes set it while backgrounded.
            try? await UNUserNotificationCenter.current().setBadgeCount(fetched.reduce(0) { $0 + $1.unreadCount })
        } catch is CancellationError {
            isLoading = false
            return
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
        let prevStatus = NetPathStatusBox()
        monitor.pathUpdateHandler = { [weak self] path in
            let wasOffline = prevStatus.value.map { $0 != .satisfied } ?? false
            prevStatus.value = path.status
            guard wasOffline, path.status == .satisfied else { return }
            Task { await self?.load(force: true) }
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
        Task { await load(force: true) }
    }

    // Switch the active club context without clearing/reloading — `books` already holds every
    // club's books, so only the filtered lists + title need to re-derive. Used by deep links
    // so Back from a deep-linked book lands on that book's club, not the default one (#57).
    func setActiveClub(_ id: UUID) {
        guard id != clubId else { return }
        let name = myClubs.first(where: { $0.id == id })?.name
        TokenStore.shared.clubId = id
        TokenStore.shared.clubName = name
        clubId = id
        clubName = name
    }
}

/// Reference holder for the previous network status. NWPathMonitor serializes
/// its handler on a single queue, so unsynchronized access to `value` is safe;
/// the box lets the @Sendable handler mutate state without capturing a `var`.
private final class NetPathStatusBox: @unchecked Sendable {
    var value: NWPath.Status?
}
