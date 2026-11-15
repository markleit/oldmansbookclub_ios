import Foundation

/// #275 — what the chat's "↑ Unread messages" pill points at (D2 in the #204 spec: any unread message above
/// the screen).
///
/// Unread is the server's rule, the one behind the library number and the badge: text, photos and
/// video from others that arrived after the read marker, plus voice from others not yet heard
/// (`GET /books/{id}/unread`, fetched when the chat opens, before opening moves the marker). Messages
/// from others that arrive while the chat is open join it. A message stops counting for the pill
/// once it has been on screen.
///
/// Nothing here looks at the chat saved on this phone. What happens to be cached says nothing about
/// what its owner has read: a saved chat left holding only your own message made days-old messages
/// look new, and a late arrival a push had already downloaded looked seen (#275).
struct UnreadAbove: Equatable {
    struct Ref: Equatable {
        let id: UUID
        let sentAt: Date
    }

    struct Pill: Equatable {
        /// The oldest unread message above the screen: reading down from it covers the rest.
        let target: UUID
        let count: Int
    }

    private(set) var unread: [UUID: Date] = [:]
    private(set) var seen: Set<UUID> = []

    /// The server's unread list. Added to, never replacing: a list fetched later in the same visit
    /// (coming back to the foreground) no longer has what this visit's open moved the marker past,
    /// but the reader still hasn't seen those.
    mutating func adopt(_ refs: [Ref]) {
        for ref in refs { unread[ref.id] = ref.sentAt }
    }

    /// A message from someone else arrived while the chat is open: unread until it's been on screen.
    mutating func arrived(_ ref: Ref) {
        unread[ref.id] = ref.sentAt
    }

    /// On screen now, or deliberately consumed ("Mark as Heard"): it no longer counts for the pill.
    mutating func markSeen(_ ids: some Sequence<UUID>) {
        seen.formUnion(ids)
    }

    /// "Mark all as read".
    mutating func clear() {
        unread.removeAll()
    }

    /// The unseen unread messages above the screen: sent before the oldest message on it, so out of
    /// sight above. `hidden` are messages that can't be shown (a blocked sender's, a deleted one).
    /// The target can be older than anything loaded yet; the chat pages back to it.
    func pill(oldestOnScreen: Ref?, hidden: Set<UUID> = []) -> Pill? {
        guard let floor = oldestOnScreen else { return nil }
        let above = unread.filter { id, sentAt in
            !seen.contains(id) && !hidden.contains(id)
                && ChatOrder.isNewer(floor.sentAt, floor.id, than: sentAt, id)
        }
        guard let oldest = above.min(by: { ChatOrder.isNewer($1.value, $1.key, than: $0.value, $0.key) })
        else { return nil }
        return Pill(target: oldest.key, count: above.count)
    }
}
