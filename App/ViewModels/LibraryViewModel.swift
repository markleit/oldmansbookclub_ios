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

    // #138 — series-grouped views of each status list. Currently Reading usually shows one
    // book, but #144's reorder view needs a [ReadItem] for every status uniformly; `.grouped`
    // degrades to one `.single` per book when nothing shares a `seriesName`, so this is a no-op
    // for the common case.
    var currentReadGroups: [ReadItem] { Self.grouped(currentReads) }
    var futureReadGroups: [ReadItem] { Self.grouped(bookList) }
    var pastReadGroups: [ReadItem] { Self.grouped(pastReads) }

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

        // Drain the outbox on every load attempt (#119), BEFORE the fetches and in its own task.
        // Not on the success path: a .refreshable can be cancelled mid-flight (#91), which
        // returns early — so hanging this off a completed fetch means pull-to-refresh, the one
        // gesture that means "reconcile with the server", is exactly the one that might not.
        // An unstructured Task doesn't inherit the refresh's cancellation, so it survives it.
        // Costs nothing when the outbox is empty, and fails harmlessly when there's no network.
        Task { await ReceiptQueue.shared.flush() }
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
            let response = try await APIClient.shared.getMyBooks()
            let fetched = response.books
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
            UnreadStore.shared.seed(response.unread)
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
            books[idx].seriesName = book.seriesName
            books[idx].seriesOrder = book.seriesOrder
            saveCache(books)
        }
    }

    // #138 — one entry per standalone book, or one per series (its members collapsed into a
    // single draggable/displayable unit). Pure and order-preserving: a series' position in the
    // result is wherever its FIRST member appears in `books`, so it inherits that book's spot in
    // whatever ordering the caller already applied (FutureReadOrder, AddedAt, ...) rather than
    // needing its own sort pass. Members within a series are always sorted by SeriesOrder,
    // regardless of the surrounding order, so a series reads in sequence even if its books
    // aren't contiguous in `books` (e.g. one was just added and hasn't been re-sequenced yet).
    static func grouped(_ books: [Book]) -> [ReadItem] {
        var result: [ReadItem] = []
        var consumed = Set<UUID>()
        for book in books {
            guard !consumed.contains(book.id) else { continue }
            if let name = book.seriesName {
                let members = books
                    .filter { $0.seriesName == name }
                    .sorted { ($0.seriesOrder ?? 0) < ($1.seriesOrder ?? 0) }
                members.forEach { consumed.insert($0.id) }
                result.append(.series(name: name, books: members))
            } else {
                consumed.insert(book.id)
                result.append(.single(book))
            }
        }
        return result
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

// #138 — a Future/Past Reads row: either one standalone book, or a whole series collapsed
// into a single unit (see LibraryViewModel.grouped).
enum ReadItem: Identifiable, Hashable {
    case single(Book)
    case series(name: String, books: [Book])

    var id: String {
        switch self {
        case .single(let book): return "book-\(book.id)"
        case .series(let name, _): return "series-\(name)"
        }
    }

    // Every book id this item represents, in display order — used to flatten a reordered
    // list of items back into a flat book-id list for the server (#137's SetFutureReadOrder
    // contract didn't change; this is where a series stays contiguous in FutureReadOrder).
    var bookIds: [UUID] {
        switch self {
        case .single(let book): return [book.id]
        case .series(_, let books): return books.map(\.id)
        }
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
