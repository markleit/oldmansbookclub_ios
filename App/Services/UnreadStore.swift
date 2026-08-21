import Foundation
import UserNotifications

// The one unread number, for every surface (chat title, club-view badge, app-icon badge,
// CarPlay). All of them read `counts`; the app icon shows the sum. Unread is defined in
// exactly one place — the server's UnreadCalculator — and this holds the answer.
//
// The server computes every count; this only caches them (#119). `seed(_:)` refreshes
// the cache on each books load, and each consuming action applies the fresh count the
// server returns. Optimistic changes in between are deltas on that cached number — never a
// second derivation of what "unread" means, which is what let the chat and the book list
// disagree.
@MainActor
final class UnreadStore: ObservableObject {
    static let shared = UnreadStore()

    private init() {
        if let raw = UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] {
            counts = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in
                UUID(uuidString: k).map { ($0, v) }
            })
            // Restored numbers are real server values from the last successful load, so the
            // badge may be written from them before this session has fetched anything.
            hasSeeded = !counts.isEmpty
        }
        dropIfNotMine()
        // Restoring counts must also repaint the icon (#119). syncBadge only fires when a count
        // CHANGES, so without this a launch that never reaches the server leaves whatever number
        // the OS was last given — which is how the icon ends up disagreeing with the library.
        syncBadge()
    }

    private func persist() {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: counts.map { ($0.key.uuidString, $0.value) }),
                                  forKey: countsKey)
    }

    // Persisted (#119): this is the ONLY client-side copy of the count, so if it lived purely in
    // memory every cold launch — and every launch with the server unreachable — would render 0
    // for books that plainly have unread messages. The values are the server's own numbers, so
    // keeping them across launches shows the last known truth rather than a fabricated zero.
    @Published private(set) var counts: [UUID: Int] = [:] {
        didSet { persist() }
    }

    private let countsKey = "unreadCounts"

    // The chat currently on screen, if any. Its count tracks what the user is doing right
    // now — each consuming action applies the count the server returned — so a concurrent
    // library reload (which fires on every foreground) must not overwrite it with a books
    // fetch that predates the last action and bounce the title's count back up.
    private var activeBookId: UUID?

    // Until a books fetch has landed, `counts` is empty and its sum is a lie — writing it would
    // wipe a correct badge that a push had set (#119). One seed is enough: the fetch returns
    // every book the user has, so from then on the sum is the server's total by construction.
    private var hasSeeded = false

    func setActiveBook(_ bookId: UUID?) { activeBookId = bookId }

    // A leaving chat clears itself only if still active — guards against clobbering when
    // navigating straight from one book to another (the new book already set itself active).
    func activeBookIdIsCurrent(_ bookId: UUID) -> Bool { activeBookId == bookId }

    var total: Int { counts.values.reduce(0, +) }

    // Counts (and the icon they drive) belong to the signed-in account — on a change, drop them
    // and clear the icon rather than showing one person's unread to the next. See AccountScope.
    private func dropIfNotMine() {
        guard AccountScope.ownerChanged("unreadStore") else { return }
        counts = [:]
        hasSeeded = false
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
    }

    // Refresh from a books fetch. Books absent from it are dropped (e.g. removed from the club)
    // so the icon-badge sum stays correct. The open chat's count is preserved — see activeBookId.
    func seed(_ unread: [UUID: Int]) {
        dropIfNotMine()
        hasSeeded = true
        var next = unread.mapValues { max(0, $0) }
        if let active = activeBookId, let local = counts[active], next[active] != nil {
            next[active] = local
        }
        counts = next
        syncBadge()
    }

    // Set a book's count outright — the value the server just returned from a consuming
    // action, which supersedes any optimistic delta applied while it was in flight.
    //
    // `writesBadge: false` is for the push path: the payload already carried a server-computed
    // TOTAL and the OS has applied it, so re-deriving the icon from a sum whose other books are
    // older than that total would replace a fresh number with a staler one (#119).
    func set(bookId: UUID, count: Int, writesBadge: Bool = true) {
        dropIfNotMine()
        let clamped = max(0, count)
        guard counts[bookId] != clamped else { return }
        counts[bookId] = clamped
        if writesBadge { syncBadge() }
    }

    // Optimistically nudge a book's count (never below zero).
    func bump(bookId: UUID, by delta: Int, writesBadge: Bool = true) {
        set(bookId: bookId, count: (counts[bookId] ?? 0) + delta, writesBadge: writesBadge)
    }

    func zero(bookId: UUID) {
        set(bookId: bookId, count: 0)
    }

    // One writer per event (#119). A push carries its own server-computed total and the OS
    // applies it, so the push path opts out here rather than racing it with a client sum; every
    // other change writes the icon, including from CarPlay with the app in the background. What
    // this sums is always server numbers — seeded per book, or returned by a consuming call.
    private func syncBadge() {
        guard hasSeeded else { return }
        let value = total
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(value) }
    }
}
