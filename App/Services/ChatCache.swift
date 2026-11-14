import Foundation

/// Single owner of the on-disk chat-message cache (`messages_<bookId>`) that `BookViewModel.load()`
/// reads to render a chat instantly. Extracted so a background prefetcher (which has no live
/// `BookViewModel`) can write a cache that `load()` fully trusts — same key, same merge/dedup rules,
/// same sort order, same bounding. If the two writers ever diverged, `load()` could resurrect a
/// ghost optimistic bubble or persist an unbounded list, so both paths must go through here.
enum ChatCache {
    /// Roughly weeks of normal chat at modest disk cost.
    static let maxCachedMessages = 1000

    static func key(bookId: UUID) -> String { "messages_\(bookId)" }

    static func load(bookId: UUID) -> [Message] {
        CacheService.shared.load([Message].self, key: key(bookId: bookId)) ?? []
    }

    /// Merge freshly-fetched server messages into an existing set, newest-first.
    ///
    /// Dedup is by server `id`; a fresh fetch wins on overlapping ids so server-side edits
    /// propagate. When an incoming message is the current user's own and carries a `clientId`,
    /// its optimistic copy (whose local id equals that `clientId`) is dropped — this reconciles a
    /// confirmed send with the optimistic bubble when the live SignalR echo was missed. The
    /// reconciled client ids are returned so the caller can clear the matching pending-send state
    /// (queue/watchdog); pass `myUserId == nil` to skip reconciliation entirely.
    static func merge(
        existing: [Message],
        incoming: [Message],
        myUserId: UUID?
    ) -> (messages: [Message], reconciledClientIds: [UUID]) {
        var byId: [UUID: Message] = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var reconciled: [UUID] = []
        for msg in incoming {
            if let cid = msg.clientId, msg.senderId == myUserId {
                byId.removeValue(forKey: cid)
                reconciled.append(cid)
            }
            byId[msg.id] = msg
        }
        let sorted = ChatOrder.sorted(byId.values)
        return (sorted, reconciled)
    }

    /// Keep an existing saved chat in step with a send confirmed while that chat isn't open (A2).
    /// With no saved chat (never opened on this phone, or iOS purged its caches) nothing is written:
    /// a "saved chat" of just this one message would be what the next open starts from (#275).
    @discardableResult
    static func addConfirmed(_ message: Message, bookId: UUID, myUserId: UUID?, waitForWrite: Bool = false) -> Bool {
        let existing = load(bookId: bookId)
        guard !existing.isEmpty else { return false }
        let merged = merge(existing: existing, incoming: [message], myUserId: myUserId)
        save(merged.messages, bookId: bookId, excludingPending: [], waitForWrite: waitForWrite)
        return true
    }

    /// Persist the newest `maxCachedMessages`, excluding still-pending optimistic sends (their ids
    /// aren't confirmed by the server yet, so persisting them would resurrect ghosts on reload).
    /// `waitForWrite` forces the encode+write to complete before returning — required on a
    /// background wake, where the app can be suspended the instant the completion handler is called
    /// and a fire-and-forget write would be lost.
    static func save(
        _ messages: [Message],
        bookId: UUID,
        excludingPending pendingIds: Set<UUID>,
        waitForWrite: Bool = false
    ) {
        let confirmed = messages.filter { !pendingIds.contains($0.id) }
        let bounded = Array(confirmed.prefix(maxCachedMessages))
        if waitForWrite {
            CacheService.shared.saveSync(bounded, key: key(bookId: bookId))
        } else {
            CacheService.shared.save(bounded, key: key(bookId: bookId))
        }
    }
}
