import Foundation

/// Warms the on-disk chat cache (`ChatCache`) for a book ahead of the user opening it, so the chat
/// renders instantly instead of waiting on a fetch. Driven by a background push wake (see
/// `AppDelegate.didReceiveRemoteNotification`) but safe to call from anywhere.
///
/// Best-effort by nature: iOS throttles background wakes (Low Power Mode, per-app budget), so this
/// degrades gracefully to the existing open-the-chat-then-fetch behavior when a wake doesn't fire.
actor MessagePrefetcher {
    static let shared = MessagePrefetcher()

    // Concurrent requests for the same book share one fetch (a burst of pushes for one chat is common).
    private var inFlight: [UUID: Task<Bool, Never>] = [:]

    private init() {}

    /// Fetch the recent page for `bookId` and merge it into the chat cache. Returns true if the
    /// cache gained messages (maps to `.newData` for the OS completion handler).
    func prefetch(bookId: UUID) async -> Bool {
        if let existing = inFlight[bookId] { return await existing.value }
        let task = Task<Bool, Never> { await MessagePrefetcher.run(bookId: bookId) }
        inFlight[bookId] = task
        let result = await task.value
        inFlight[bookId] = nil
        return result
    }

    private static func run(bookId: UUID) async -> Bool {
        // Refresh headlessly if needed — the token may have expired while suspended.
        guard await APIClient.shared.ensureFreshToken() else { return false }
        guard let fetched = try? await APIClient.shared.getMessages(bookId: bookId), !fetched.isEmpty else {
            return false
        }

        let existing = ChatCache.load(bookId: bookId)
        let existingIds = Set(existing.map(\.id))
        let merged = ChatCache.merge(existing: existing, incoming: fetched, myUserId: TokenStore.shared.userId)

        // #94: predownload the audio for NEW voice messages this wake pulled in, so playback
        // (not just the bubble) is instant when the user opens the chat. Best-effort within the
        // background window; anything iOS doesn't let us finish falls back to today's on-demand
        // fetch on play — strictly better than before, never worse.
        for m in merged.messages where m.type == .voice && !existingIds.contains(m.id) {
            if let u = m.mediaUrl, let url = URL(string: u) { AudioCache.shared.prefetch(url) }
        }

        // Report .newData only when the id set actually changed, so iOS keeps our background
        // wakes scheduled accurately. The persisted cache holds only confirmed messages, and the
        // merge inputs carry none of the local optimistic sends, so nothing pending is at risk —
        // hence no exclusion set. waitForWrite: the app can be suspended the moment we return.
        let changed = Set(merged.messages.map(\.id)) != existingIds
        ChatCache.save(merged.messages, bookId: bookId, excludingPending: [], waitForWrite: true)
        return changed
    }
}
