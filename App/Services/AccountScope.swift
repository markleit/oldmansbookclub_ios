import Foundation

// Local state that belongs to one signed-in account (#119).
//
// Caches and outboxes live in UserDefaults, which outlives a sign-out. On a shared device that
// means the next person inherits them — and an outbox is worse than a cache, because it would
// replay the previous account's marks under the new account's token, against a club they may
// well both belong to.
//
// Rather than relying on every sign-out path to remember to clear (a forced sign-out on a
// rejected token doesn't go through the same door), each store stamps its data with the owner
// and checks before it is used. State can only ever be read or sent by the account that made it.
enum AccountScope {
    private static let prefix = "accountScopeOwner."

    // True when the signed-in account differs from the one this store last saw — i.e. whatever
    // it is holding belongs to someone else and must be dropped. Re-stamps as a side effect,
    // so the answer is true exactly once per change.
    static func ownerChanged(_ key: String) -> Bool {
        let defaults = UserDefaults.standard
        let stampKey = prefix + key
        let current = TokenStore.shared.userId?.uuidString
        let stamped = defaults.string(forKey: stampKey)
        guard stamped != current else { return false }
        defaults.set(current, forKey: stampKey)
        return true
    }
}
