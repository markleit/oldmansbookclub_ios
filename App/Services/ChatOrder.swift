import Foundation

/// #204 PR 6 — the one order every chat is in: newest first by tap time (`sentAt`), the order the
/// server pages in. A message that arrives late — held up by an outage, or a slow video that
/// finished after a quick voice message tapped later — goes where it was tapped, not at the bottom.
enum ChatOrder {
    /// `a` comes before (is newer than) `b`. Equal tap times fall back to the id, so every list on
    /// the phone agrees.
    static func isNewer(_ a: Message, than b: Message) -> Bool {
        a.sentAt != b.sentAt ? a.sentAt > b.sentAt : a.id.uuidString > b.id.uuidString
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

    /// What "↑ New message above" points at: of the messages from others new since `previous`, the
    /// oldest that landed above what was already the newest — out of sight of someone reading at the
    /// bottom. Nil on a first load (nothing was seen before) and when everything new is at the bottom.
    static func arrivedAbove(previous: [Message], current: [Message], me: UUID?) -> UUID? {
        guard let previousNewest = previous.first else { return nil }
        let known = Set(previous.map(\.id))
        return current
            .filter { !known.contains($0.id) && $0.senderId != me && isNewer(previousNewest, than: $0) }
            .min { isNewer($1, than: $0) }   // the oldest
            .map(\.id)
    }
}
