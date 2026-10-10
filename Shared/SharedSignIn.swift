import Foundation
import Security

// #204 (PR 3) — the Share extension keeps itself signed in.
//
// The API's access token lasts one hour; the app refreshes it whenever a request is refused. The
// extension used to read the app's token and never refresh it (a comment assumed it "lives a
// year"), so sharing after the app had been idle for an hour failed with "sign in" even though
// the session was fine. It now refreshes the same way the app does and writes the new token back
// to the shared keychain item, where the app picks it up too (TokenStore reads the keychain on
// every access).
//
// Safe to run alongside the app: refresh tokens are NOT rotated on use (AuthController, pinned by
// AuthTests.A_refresh_token_is_not_rotated_on_use), so the app and the extension refreshing at
// the same moment both get valid tokens and neither invalidates the other. Compiled into both
// targets so the app's unit tests cover it.

/// When a JWT stops being usable, read from its own `exp` claim. No signature check — the server
/// does that; this only decides whether to refresh before sending.
enum JWTExpiry {
    static func expiresAt(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if base64.count % 4 > 0 { base64 += String(repeating: "=", count: 4 - base64.count % 4) }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// True when the token is unreadable, expired, or expires within `leeway` — refresh first
    /// rather than send a request that's about to be refused.
    static func needsRefresh(_ jwt: String, now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiry = expiresAt(jwt) else { return true }
        return expiry.timeIntervalSince(now) <= leeway
    }
}

/// Where the tokens live. The real one is the keychain item the app writes; tests use a fake.
protocol SignInStore: Sendable {
    func accessToken() -> String?
    func refreshToken() -> String?
    func saveAccessToken(_ token: String)
}

/// The app's own keychain items (TokenStore), via the keychain group both targets share.
struct KeychainSignInStore: SignInStore {
    func accessToken() -> String? { read(SharedContainer.keychainTokenAccount) }
    func refreshToken() -> String? { read(SharedContainer.keychainRefreshAccount) }

    /// Updates the existing item only. If there's no item the user isn't signed in, and creating
    /// one from here would be wrong — sign-in belongs to the app.
    func saveAccessToken(_ token: String) {
        let attributes: [CFString: Any] = [kSecValueData: Data(token.utf8)]
        SecItemUpdate(query(SharedContainer.keychainTokenAccount) as CFDictionary, attributes as CFDictionary)
    }

    private func query(_ account: String) -> [CFString: Any] {
        var q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: SharedContainer.keychainService,
            kSecAttrAccount: account
        ]
        if let group = SharedContainer.keychainAccessGroup { q[kSecAttrAccessGroup] = group }
        return q
    }

    private func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum SignInError: Error, Equatable {
    /// No session, or the server refused the refresh token: only the app can sign in again.
    case signedOut
    /// Couldn't reach the server to refresh (no network, server down). The session may be fine.
    case unreachable
}

/// Hands out a usable access token, refreshing it when it's expired or the server refused it.
/// An actor so concurrent requests (the share sheet loads books and clubs at once) share ONE
/// refresh instead of each starting their own.
actor SignInSession {
    private let baseURL: URL
    private let session: URLSession
    private let store: SignInStore
    private let now: @Sendable () -> Date
    private var inFlight: Task<String, Error>?

    init(baseURL: URL, store: SignInStore, session: URLSession = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL
        self.store = store
        self.session = session
        self.now = now
    }

    /// A token to send now: the stored one if it has more than a minute left, else a fresh one.
    func accessToken() async throws -> String {
        guard let token = store.accessToken() else { throw SignInError.signedOut }
        guard JWTExpiry.needsRefresh(token, now: now()) else { return token }
        return try await refresh()
    }

    /// The server refused `rejected` (401). If the stored token has changed since — the app or
    /// another request already refreshed — use that; otherwise refresh.
    func tokenAfterRejection(of rejected: String) async throws -> String {
        if let current = store.accessToken(), current != rejected,
           !JWTExpiry.needsRefresh(current, now: now()) {
            return current
        }
        return try await refresh()
    }

    private func refresh() async throws -> String {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await performRefresh() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> String {
        guard let refreshToken = store.refreshToken() else { throw SignInError.signedOut }
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw SignInError.unreachable }
        guard let http = response as? HTTPURLResponse else { throw SignInError.unreachable }
        // Same rule as the app (APIClient.attemptRefresh): only an explicit 401/403 means the
        // session is over. Anything else is transient — never treat it as signed out.
        if http.statusCode == 401 || http.statusCode == 403 { throw SignInError.signedOut }
        guard (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else { throw SignInError.unreachable }
        store.saveAccessToken(access)
        return access
    }
}
