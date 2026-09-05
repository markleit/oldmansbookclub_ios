import Foundation

// The single notion of "have I heard this voice message?" (#119).
//
// The server owns the fact (MessageHeards). This holds two things and neither is a rival
// authority:
//
//   confirmed — a local CACHE of the server's heard set, replaced (not merged) whenever the
//               server tells us the truth for a book, so a stale entry can go away again;
//   pending   — an OUTBOX of marks made here that the server hasn't acknowledged yet.
//
// heard = confirmed ∪ pending. That union is what makes offline work without a second source
// of truth: a mark is "heard" from the instant you make it, but it isn't *done* until the
// server acks it and it moves from pending to confirmed. Nothing ever silently becomes
// permanent local truth — which is exactly how the old sticky `completed` flag diverged from
// the server forever when a receipt was dropped.
@MainActor
final class HeardStore: ObservableObject {
    static let shared = HeardStore()

    private let confirmedKey = "heardConfirmed"
    private let pendingKey = "heardPending"

    // Injected purely for testability (#126). `shared` passes nothing, so production behaviour is
    // byte-for-byte what it was: UserDefaults.standard and the Keychain-backed account identity.
    // A test passes a scratch UserDefaults(suiteName:) and a fixed id, and gets a store with no
    // Keychain access and no shared global state between cases.
    private let defaults: UserDefaults
    private let currentUserId: () -> String?

    // Cache of server truth.
    @Published private(set) var confirmed: Set<UUID>
    // messageId -> bookId, so a flush knows where to send each mark.
    @Published private(set) var pending: [UUID: UUID]

    init(defaults: UserDefaults = .standard, currentUserId: @escaping () -> String? = { TokenStore.shared.userId?.uuidString }) {
        self.defaults = defaults
        self.currentUserId = currentUserId
        let d = defaults
        confirmed = (d.array(forKey: confirmedKey) as? [String]).map { Set($0.compactMap(UUID.init)) } ?? []
        if let raw = d.dictionary(forKey: pendingKey) as? [String: String] {
            pending = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in
                guard let m = UUID(uuidString: k), let b = UUID(uuidString: v) else { return nil }
                return (m, b)
            })
        } else {
            pending = [:]
        }
        // Cheap and worth it once at launch: without this, a cold start signed in as someone
        // else would render the previous account's green bubbles until the first book load.
        dropIfNotMine()
    }

    // Deliberately does no account check: it runs per voice bubble on every render, and every
    // path that could act on stale state (seed, markHeard, the outbox) checks before it does.
    func isHeard(_ id: UUID) -> Bool { confirmed.contains(id) || pending[id] != nil }

    // Drop everything if the signed-in account changed — this state is one account's.
    private func dropIfNotMine() {
        guard AccountScope.ownerChanged("heardStore", defaults: defaults, currentUserId: currentUserId()) else { return }
        confirmed = []
        pending = [:]
        persist()
    }

    // Mark heard locally and hand the marks to the outbox. Instant on screen; the network
    // attempt happens in `push`, and anything that fails simply stays pending.
    func markHeard(_ ids: [UUID], bookId: UUID) {
        dropIfNotMine()
        guard !ids.isEmpty else { return }
        for id in ids where !confirmed.contains(id) { pending[id] = bookId }
        persist()
    }

    // The server has acknowledged these — move them out of the outbox into the cache.
    func confirm(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            pending.removeValue(forKey: id)
            confirmed.insert(id)
        }
        persist()
    }

    // Reconcile the cache with server truth for one book, and return the ids the server is
    // still missing so the caller can push them up.
    //
    // `voiceIds` scopes the replacement: within the set of ids we have data for, the server's
    // answer wins outright — an entry it doesn't list is dropped from the cache. Marks still
    // sitting in the outbox survive, because those the server simply hasn't been told yet.
    //
    // `legacyHeardIds` are ids the pre-#119 build recorded in PlaybackProgressStore. Those were
    // written straight to sticky local state with no outbox, so a lost receipt left no trace to
    // retry — they're adopted into the outbox once here and pushed up like any other mark.
    func seed(serverHeardIds: [UUID], voiceIds: [UUID], legacyHeardIds: [UUID], bookId: UUID) -> [UUID] {
        dropIfNotMine()
        let server = Set(serverHeardIds)
        let legacy = Set(legacyHeardIds)
        confirmed.formUnion(server)
        // The server already knows about these, so the outbox is done with them. Without this
        // they'd linger and be re-sent on the next flush for no reason.
        for id in server { pending.removeValue(forKey: id) }

        for id in voiceIds where !server.contains(id) && pending[id] == nil {
            if legacy.contains(id) {
                pending[id] = bookId     // heard on this device before outboxes existed
            } else {
                confirmed.remove(id)     // stale cache entry — the server says otherwise
            }
        }
        persist()

        return pending.compactMap { $0.value == bookId && !server.contains($0.key) ? $0.key : nil }
    }

    // Everything queued for one book, for a retry that isn't tied to a book load.
    func pendingIds(bookId: UUID) -> [UUID] {
        dropIfNotMine()
        return pending.compactMap { $0.value == bookId ? $0.key : nil }
    }

    var pendingBookIds: Set<UUID> {
        dropIfNotMine()
        return Set(pending.values)
    }

    // The server has told us it will never accept these — your own message, a deleted one, an id
    // it doesn't recognise. Keeping them would mean retrying forever, so they leave the outbox.
    // They stay "heard" on screen only if they're in the cache on their own merit.
    func abandon(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { pending.removeValue(forKey: id) }
        persist()
    }

    private func persist() {
        let d = defaults
        d.set(confirmed.map(\.uuidString), forKey: confirmedKey)
        d.set(Dictionary(uniqueKeysWithValues: pending.map { ($0.key.uuidString, $0.value.uuidString) }),
              forKey: pendingKey)
    }
}
