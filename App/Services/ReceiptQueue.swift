import Foundation

// Durable retry for read/heard receipts (#119).
//
// Both receipts are written to device-local state FIRST (PlaybackProgressStore.completed,
// UnreadStore) and only then posted to the server. Those local writes are sticky, so a POST
// that never lands leaves the device permanently believing something the server doesn't —
// and because heard-state only ever syncs server→device, nothing corrects it. The unread
// count then floors at the lost receipts forever.
//
// So every receipt goes through here: try it now, and if it fails, persist it and retry on
// the next foreground or SignalR reconnect. Entries are tiny and idempotent server-side, so
// replaying one costs nothing.
@MainActor
final class ReceiptQueue {
    static let shared = ReceiptQueue()

    struct Receipt: Codable, Equatable {
        enum Kind: String, Codable { case heard, read, heardAll }
        let kind: Kind
        let bookId: UUID
        let messageId: UUID?   // nil for .heardAll
    }

    private let key = "pendingReceipts"
    private let maxPending = 500
    private var pending: [Receipt]
    private var isFlushing = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Receipt].self, from: data) {
            pending = decoded
        } else {
            pending = []
        }
    }

    // MARK: - Sending

    func markHeard(bookId: UUID, messageId: UUID) async {
        await send(Receipt(kind: .heard, bookId: bookId, messageId: messageId))
    }

    func markRead(bookId: UUID, messageId: UUID) async {
        await send(Receipt(kind: .read, bookId: bookId, messageId: messageId))
    }

    func markAllHeard(bookId: UUID) async {
        await send(Receipt(kind: .heardAll, bookId: bookId, messageId: nil))
    }

    // Push a batch of ids the server is missing. On failure the ids are queued individually —
    // the batch endpoint is only a bandwidth optimization, replaying one at a time is equivalent.
    func markHeardBatch(bookId: UUID, messageIds: [UUID]) async {
        guard !messageIds.isEmpty else { return }
        do {
            try await APIClient.shared.markHeardBatch(bookId: bookId, messageIds: messageIds)
        } catch {
            for id in messageIds { enqueue(Receipt(kind: .heard, bookId: bookId, messageId: id)) }
        }
    }

    private func send(_ receipt: Receipt) async {
        do {
            try await perform(receipt)
        } catch {
            enqueue(receipt)
        }
    }

    private func perform(_ receipt: Receipt) async throws {
        switch receipt.kind {
        case .heard:
            guard let id = receipt.messageId else { return }
            try await APIClient.shared.markHeard(bookId: receipt.bookId, messageId: id)
        case .read:
            guard let id = receipt.messageId else { return }
            try await APIClient.shared.markRead(bookId: receipt.bookId, messageId: id)
        case .heardAll:
            try await APIClient.shared.markAllHeard(bookId: receipt.bookId)
        }
    }

    // MARK: - Queue

    private func enqueue(_ receipt: Receipt) {
        switch receipt.kind {
        case .read:
            // Only the newest read marker per book matters, and the server now refuses to move
            // the marker backwards anyway — keep one entry per book.
            pending.removeAll { $0.kind == .read && $0.bookId == receipt.bookId }
        case .heardAll:
            // Supersedes every pending per-message heard for that book.
            pending.removeAll { $0.bookId == receipt.bookId && ($0.kind == .heard || $0.kind == .heardAll) }
        case .heard:
            // A pending mark-all already covers this one.
            if pending.contains(where: { $0.kind == .heardAll && $0.bookId == receipt.bookId }) { return }
            if pending.contains(receipt) { return }
        }
        pending.append(receipt)
        if pending.count > maxPending { pending.removeFirst(pending.count - maxPending) }
        persist()
    }

    // Retry everything queued. Stops at the first failure — if one call can't reach the server
    // the rest won't either, and they keep their order for the next attempt.
    func flush() async {
        guard !isFlushing, !pending.isEmpty, TokenStore.shared.token != nil else { return }
        isFlushing = true
        defer { isFlushing = false }

        while let next = pending.first {
            do {
                try await perform(next)
            } catch {
                return
            }
            // Re-check the head: enqueue() may have collapsed entries while we awaited.
            if pending.first == next { pending.removeFirst() }
            else { pending.removeAll { $0 == next } }
            persist()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
