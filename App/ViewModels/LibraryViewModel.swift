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

    // Foreground/appear fire load() often (every scenePhase == .active, tab switches).
    // Skip a network refetch if we just did one, so quick app-switches don't churn the
    // list. User-driven loads (pull-to-refresh, retry, club switch, reconnect) pass force.
    private var lastLoadedAt: Date?
    private let minReloadInterval: TimeInterval = 30

    private func loadCache() {
        books = Self.cachedBooks()
    }

    // Read-only access to the persisted book list, so CarPlay can instant-paint its root from the
    // phone's cache before the network returns (#101) instead of sitting on "Loading…".
    static func cachedBooks() -> [Book] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cached = try? decoder.decode([Book].self, from: data) else { return [] }
        return cached
    }

    private func saveCache(_ books: [Book]) {
        guard let data = try? Self.encoder.encode(books) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    func load(force: Bool = false) async {
        if !force, let last = lastLoadedAt, Date().timeIntervalSince(last) < minReloadInterval {
            return
        }
        // Every @Published write here re-renders LibraryView; a re-render mid-refresh cancels
        // the .refreshable Task (→ -999 → blank/flicker). So only write when the value actually
        // changes — a refresh where nothing changed must produce zero re-renders until the end.
        if books.isEmpty { loadCache() }
        if isOffline { isOffline = false }
        let wantLoading = books.isEmpty
        if isLoading != wantLoading { isLoading = wantLoading }
        if errorMessage != nil { errorMessage = nil }

        // Only trust an authoritative clubs list to (re)select the active club. A *failed*
        // fetch must NOT be read as "you have no clubs" — doing so wiped clubId to nil and
        // left every section filtering on nil → a silent blank page with no error/retry.
        let clubs: [Club]
        do {
            clubs = try await APIClient.shared.getMyClubs()
        } catch let error where error.isCancellation {
            // A cancelled request (e.g. the refreshable's Task torn down by a re-render) is NOT
            // a failure — never mutate club/books/error state on it, or we blank a good UI.
            isLoading = false
            return
        } catch {
            // Keep the current club + cached books; surface offline/error instead of blanking.
            if books.isEmpty { errorMessage = "Unable to load. Check your connection." }
            else { isOffline = true }
            isLoading = false
            return
        }
        if myClubs.map({ "\($0.id)|\($0.name)" }) != clubs.map({ "\($0.id)|\($0.name)" }) {
            myClubs = clubs
        }
        if TokenStore.shared.clubId == nil || !clubs.contains(where: { $0.id == TokenStore.shared.clubId }) {
            let first = clubs.first
            TokenStore.shared.clubId = first?.id
            TokenStore.shared.clubName = first?.name
        }

        let newClubId = TokenStore.shared.clubId
        if clubId != newClubId { clubId = newClubId }
        let newClubName = TokenStore.shared.clubName ?? myClubs.first(where: { $0.id == clubId })?.name
        if clubName != newClubName { clubName = newClubName }

        guard clubId != nil else {
            isLoading = false
            return
        }

        do {
            let coversBefore = books.map { "\($0.id)|\($0.coverBlobUrl ?? "")" }
            let fetched = try await APIClient.shared.getMyBooks()
            if books != fetched {
                books = fetched
                saveCache(fetched)
            }
            lastLoadedAt = Date()
            // Only bust cover-image caches when a cover actually changed — bumping the
            // token unconditionally re-renders every cover on each foreground (the visible
            // "flicker"), even when nothing changed.
            let coversAfter = fetched.map { "\($0.id)|\($0.coverBlobUrl ?? "")" }
            if coversBefore != coversAfter { imageRefreshToken = UUID() }
            // Reconcile the shared unread store (and the app icon badge, which it owns)
            // to server truth on every load (initial, pull-to-refresh, foreground). This
            // is the convergence point that heals any optimistic local drift; pushes set
            // the badge while backgrounded.
            UnreadStore.shared.seed(from: fetched)
        } catch let error where error.isCancellation {
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

    func bookUpdated(_ book: Book) {
        if let idx = books.firstIndex(where: { $0.id == book.id }) {
            books[idx].title = book.title
            books[idx].author = book.author
            saveCache(books)
        }
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

extension Error {
    /// A Swift task cancellation or a URLSession `-999` cancelled request — both mean the
    /// request was superseded/torn down, not that it failed. Callers must not surface these
    /// as errors or mutate UI state on them.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

/// Reference holder for the previous network status. NWPathMonitor serializes
/// its handler on a single queue, so unsynchronized access to `value` is safe;
/// the box lets the @Sendable handler mutate state without capturing a `var`.
private final class NetPathStatusBox: @unchecked Sendable {
    var value: NWPath.Status?
}
