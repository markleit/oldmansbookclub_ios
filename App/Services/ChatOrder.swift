import Foundation

/// #204 PR 6 — the one order every chat is in: newest first by tap time (`sentAt`), the order the
/// server pages in. A message that arrives late — held up by an outage, or a slow video that
/// finished after a quick voice message tapped later — goes where it was tapped, not at the bottom.
enum ChatOrder {
    /// `a` comes before (is newer than) `b`. Equal tap times fall back to the id, so every list on
    /// the phone agrees.
    static func isNewer(_ a: Message, than b: Message) -> Bool {
        isNewer(a.sentAt, a.id, than: b.sentAt, b.id)
    }

    /// The same order for a message known only by its tap time and id (#275: the server's unread
    /// list, which can name messages not loaded yet).
    static func isNewer(_ aSentAt: Date, _ aId: UUID, than bSentAt: Date, _ bId: UUID) -> Bool {
        aSentAt != bSentAt ? aSentAt > bSentAt : aId.uuidString > bId.uuidString
    }

    /// The tap time to page older history from, given the newest page as the server returned it:
    /// that page is the first `pageSize` messages, and anything after them is a late arrival
    /// (`include_late`) with an older tap time. Paging from a late arrival would skip everything
    /// between it and the page (#275). Nil when there's nothing to page from.
    static func pageFloor(of newestPage: [Message], pageSize: Int) -> Date? {
        newestPage.count >= pageSize ? newestPage[pageSize - 1].sentAt : newestPage.last?.sentAt
    }

    /// Where `message` goes in a newest-first list.
    static func insertionIndex(of message: Message, in messages: [Message]) -> Int {
        messages.firstIndex { isNewer(message, than: $0) } ?? messages.count
    }

    static func sorted(_ messages: some Sequence<Message>) -> [Message] {
        messages.sorted(by: isNewer)
    }

    /// The message the read marker should point at: the latest to *arrive*. The server moves the
    /// marker by arrival time, so marking the newest by tap time would leave a late arrival behind
    /// it counted as unread forever — or, read the other way, skip it.
    static func latestArrival(in messages: [Message]) -> Message? {
        messages.max { ($0.receivedAt ?? $0.sentAt) < ($1.receivedAt ?? $1.sentAt) }
    }
}
