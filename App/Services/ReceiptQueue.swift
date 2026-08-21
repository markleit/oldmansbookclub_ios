import Foundation

// Outbox for the actions that consume messages (#119).
//
// Every one of them is applied locally first so the UI moves instantly, then sent. A send that
// fails is kept and retried on the next foreground or SignalR reconnect — without that, the
// local change would be a promise the server never learned about, and the two would disagree
// forever.
//
// Per-message heard marks live in HeardStore (it owns that state); this drives them onto the
// wire. Read markers and "mark all" are book-level, so they're queued here directly.
//
// Every call answers with the book's authoritative unread count, which is applied to
// UnreadStore — so a consuming action doubles as a resync of the number.
@MainActor
final class ReceiptQueue {
    static let shared = ReceiptQueue()

    struct Receipt: Codable, Equatable {
        enum Kind: String, Codable { case read, heardAll }
        let kind: Kind
        let bookId: UUID
        let messageId: UUID?   // nil for .heardAll
    }

    private let key = "pendingReceipts"
    private let maxPending = 200
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

    // Queued receipts belong to the account that made them; replaying one under a different
    // sign-in would mark the WRONG person's messages read. See AccountScope.
    private func dropIfNotMine() {
        guard AccountScope.ownerChanged("receiptQueue") else { return }
        pending = []
        persist()
    }

    // MARK: - Book-level receipts

    func markRead(bookId: UUID, messageId: UUID) async {
        await send(Receipt(kind: .read, bookId: bookId, messageId: messageId))
    }

    func markAllHeard(bookId: UUID) async {
        await send(Receipt(kind: .heardAll, bookId: bookId, messageId: nil))
    }

    // A 4xx is an answer, not an outage: the book is gone, or was never ours. Retrying can't
    // change that, so the receipt is dropped instead of living in the queue forever. Anything
    // else — no network, a 5xx — is worth another go.
    private func isPermanentRefusal(_ error: Error) -> Bool {
        if case APIError.serverError(let code) = error { return (400..<500).contains(code) }
        return false
    }

    private func send(_ receipt: Receipt) async {
        dropIfNotMine()
        do {
            try await perform(receipt)
        } catch {
            if !isPermanentRefusal(error) { enqueue(receipt) }
        }
    }

    private func perform(_ receipt: Receipt) async throws {
        switch receipt.kind {
        case .read:
            guard let id = receipt.messageId else { return }
            apply(try await APIClient.shared.markRead(bookId: receipt.bookId, messageId: id),
                  to: receipt.bookId)
        case .heardAll:
            apply(try await APIClient.shared.markAllHeard(bookId: receipt.bookId), to: receipt.bookId)
        }
    }

    // MARK: - Heard marks

    // Send the heard marks HeardStore is holding for a book. Confirmed ids leave the outbox;
    // a failure leaves them exactly where they were, still showing as heard on screen.
    func pushHeard(bookId: UUID, ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        do {
            let result = try await APIClient.shared.markHeardBatch(bookId: bookId, messageIds: ids)
            apply(result.unreadCount, to: bookId)
            // Confirm exactly what the server says it holds, and stop asking about the rest.
            // Anything it won't take — your own message, one since deleted, an id from another
            // book — would otherwise be retried on every flush for the life of the install.
            HeardStore.shared.confirm(result.heard)
            HeardStore.shared.abandon(Array(Set(ids).subtracting(result.heard)))
        } catch {
            // Transport failure leaves them pending for the next flush; a refusal retires them.
            if isPermanentRefusal(error) { HeardStore.shared.abandon(ids) }
        }
    }

    private func apply(_ count: Int?, to bookId: UUID) {
        guard let count else { return }
        UnreadStore.shared.set(bookId: bookId, count: count)
    }

    // MARK: - Queue

    private func enqueue(_ receipt: Receipt) {
        switch receipt.kind {
        case .read:
            // Only the newest read marker per book matters, and the server refuses to move the
            // marker backwards anyway — keep one entry per book.
            pending.removeAll { $0.kind == .read && $0.bookId == receipt.bookId }
        case .heardAll:
            pending.removeAll { $0 == receipt }
        }
        pending.append(receipt)
        if pending.count > maxPending { pending.removeFirst(pending.count - maxPending) }
        persist()
    }

    // Retry everything outstanding: queued book-level receipts, then any heard marks still
    // waiting. Stops at the first failure — if one call can't reach the server the rest won't
    // either, and they keep their order for the next attempt.
    func flush() async {
        dropIfNotMine()
        guard !isFlushing, TokenStore.shared.token != nil else { return }
        isFlushing = true
        defer { isFlushing = false }

        while let next = pending.first {
            do {
                try await perform(next)
            } catch {
                // A refusal must not wedge the queue behind it — drop it and carry on.
                guard isPermanentRefusal(error) else { return }
                pending.removeAll { $0 == next }
                persist()
                continue
            }
            if pending.first == next { pending.removeFirst() } else { pending.removeAll { $0 == next } }
            persist()
        }

        for bookId in HeardStore.shared.pendingBookIds {
            await pushHeard(bookId: bookId, ids: HeardStore.shared.pendingIds(bookId: bookId))
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
