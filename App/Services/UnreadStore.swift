import Foundation
import UserNotifications

// Single source of truth for unread message counts across every surface (chat title,
// club-view badge, app-icon badge). All three read from `counts`; the app icon shows
// the sum. Definition matches the server's UnreadCalculator (voice = not-yet-heard,
// text/photo/video = newer than last-seen; from others, not deleted, not blocked).
//
// Server remains the durable authority: `seed(from:)` runs on every books load and
// reconciles any optimistic local drift back to server truth. In between, local
// read/heard actions mutate the store immediately so surfaces update without waiting
// for a reload.
@MainActor
final class UnreadStore: ObservableObject {
    static let shared = UnreadStore()
    private init() {}

    @Published private(set) var counts: [UUID: Int] = [:]

    // The chat currently on screen, if any. While a chat is open it marks messages
    // read/heard locally and owns its own count, so a concurrent library reload (which
    // fires on every foreground) must NOT overwrite it with server truth that may lag a
    // just-played/-read action — that would bounce the open title's count back up.
    private var activeBookId: UUID?

    func setActiveBook(_ bookId: UUID?) { activeBookId = bookId }

    // A leaving chat clears itself only if still active — guards against clobbering when
    // navigating straight from one book to another (the new book already set itself active).
    func activeBookIdIsCurrent(_ bookId: UUID) -> Bool { activeBookId == bookId }

    var total: Int { counts.values.reduce(0, +) }

    // Reconcile to server truth. Books absent from the fetch are dropped (e.g. removed
    // from the club) so the icon-badge sum stays correct. The open chat's count is
    // preserved — it's the live authority while on screen.
    func seed(from books: [Book]) {
        var next = Dictionary(books.map { ($0.id, max(0, $0.unreadCount)) },
                              uniquingKeysWith: { first, _ in first })
        if let active = activeBookId, let local = counts[active], next[active] != nil {
            next[active] = local
        }
        counts = next
        syncBadge()
    }

    // Set a book's count outright — used when a surface can compute the exact unread
    // locally (the open chat, which holds the full message list + heard state).
    func set(bookId: UUID, count: Int) {
        let clamped = max(0, count)
        guard counts[bookId] != clamped else { return }
        counts[bookId] = clamped
        syncBadge()
    }

    // Optimistically nudge a book's count (never below zero).
    func bump(bookId: UUID, by delta: Int) {
        set(bookId: bookId, count: (counts[bookId] ?? 0) + delta)
    }

    func zero(bookId: UUID) {
        set(bookId: bookId, count: 0)
    }

    private func syncBadge() {
        let value = total
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(value) }
    }
}
