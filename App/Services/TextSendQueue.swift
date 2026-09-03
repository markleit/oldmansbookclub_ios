import Foundation

// #146 — durable outbox for text sends, so a force-quit between "tap send" and "server ack"
// doesn't lose the message with zero trace (confirmed: nothing else persists an in-flight text
// send — ChatCache deliberately excludes pending sends from its disk cache).
//
// Deliberately its own small queue rather than sharing code with ReceiptQueue, even though the
// persistence shape (UserDefaults-JSON, retry-on-foreground) is the same: ReceiptQueue backs the
// read/heard-receipt system, which has a real history of subtle bugs (the heard-state divergence
// saga, #102/#107/#108/#119) — refactoring that working code into a shared generic base for a
// stylistic win isn't worth the risk. If a third consumer of this shape shows up later, that's
// the point to extract one.
//
// Unlike MediaSendQueue (which has real file bytes to manage and its own OS-level background
// upload), a text body is small enough that a normal foreground POST always completes in well
// under BackgroundTaskBox's ~30s grace — the actual gap this closes is durability, not transit
// time, so retrying is driven by BookViewModel itself on the same triggers already used for
// media (foreground, per-book on load), not a separate background transport.
@MainActor
final class TextSendQueue {
    static let shared = TextSendQueue()

    struct PendingSend: Codable, Identifiable {
        var id: UUID { clientId }
        let clientId: UUID
        let bookId: UUID
        let clubId: UUID
        let body: String
        let parentMessageId: UUID?
        let queuedAt: Date
    }

    private(set) var items: [PendingSend] = []

    private let key = "pendingTextSends"

    private init() {
        load()
    }

    func enqueue(_ item: PendingSend) {
        items.append(item)
        save()
    }

    func remove(clientId: UUID) {
        items.removeAll { $0.clientId == clientId }
        save()
    }

    func items(for bookId: UUID) -> [PendingSend] {
        items.filter { $0.bookId == bookId }
    }

    // A 4xx is an answer, not an outage — matches ReceiptQueue's isPermanentRefusal. Retrying
    // can't change a validation/rate-limit/not-found response, so the caller should drop it
    // (leave the bubble .failed with no further auto-retry) rather than keep it queued forever.
    func isPermanentRefusal(_ error: Error) -> Bool {
        if case ChatError.serverError = error { return true }
        if case APIError.serverError(let code) = error { return (400..<500).contains(code) }
        return false
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([PendingSend].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
