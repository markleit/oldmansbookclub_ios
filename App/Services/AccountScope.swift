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
    // `defaults` and `currentUserId` are injectable ONLY so this can be unit-tested: the real
    // identity comes from the Keychain via TokenStore, which a test process has no business
    // touching. Every production call site uses the defaults and behaves exactly as before.
    static func ownerChanged(
        _ key: String,
        defaults: UserDefaults = .standard,
        currentUserId: String? = TokenStore.shared.userId?.uuidString
    ) -> Bool {
        let stampKey = prefix + key
        let current = currentUserId
        let stamped = defaults.string(forKey: stampKey)
        guard stamped != current else { return false }
        defaults.set(current, forKey: stampKey)
        // No previous stamp means this data was written before scoping existed — on an install
        // that has only ever had one account. It belongs to whoever is signed in now, so ADOPT
        // it. Wiping on first run would erase every resume position on upgrade AND destroy the
        // pre-#119 heard flags that the legacy migration reads, which is the one thing that
        // repairs users already diverged.
        return stamped != nil
    }
}
