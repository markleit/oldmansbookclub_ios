import Foundation

// Where the app talks to (#120).
//
// This used to be two independent `#if targetEnvironment(simulator)` forks — one in APIClient,
// one in ChatService — which meant a physical device could ONLY ever reach production. Anything
// device-only (push, CarPlay, background wake, outage recovery) could therefore only be exercised
// against real member data, and any client change depending on new server behaviour was untestable
// until that server change was already deployed to prod.
//
// In DEBUG the host is resolved at runtime so a device can be pointed at a laptop or a staging
// slot. In RELEASE it compiles down to the production literal — no lookup, no storage read, no way
// to change it — so a shipped build behaves exactly as it did before this file existed.
//
// Both callers MUST come through here. Pointing only the REST client somewhere new would leave
// chat silently talking to production, which is worse than not switching at all.
enum ServerEnvironment {

    static let productionURLString = "https://oldmansbookclub-api.azurewebsites.net"

    #if DEBUG

    private static let overrideKey = "debugServerBaseURL"

    /// A local `dotnet run`. Reachable as-is from the simulator; from a device it must be the
    /// Mac's LAN address instead, which is what the editable field is for.
    static let localhostURLString = "http://localhost:5235"

    /// What the compile-time fork used to do. Still the default, so an untouched DEBUG build
    /// behaves exactly as it did before: simulator → localhost, device → production.
    static var defaultURLString: String {
        #if targetEnvironment(simulator)
        return localhostURLString
        #else
        return productionURLString
        #endif
    }

    static var baseURLString: String {
        // A stored value that no longer parses (hand-typed, or a preset that has since changed)
        // must not brick the app — fall back rather than force-unwrap a nil URL below.
        if let stored = UserDefaults.standard.string(forKey: overrideKey),
           let clean = sanitized(stored) {
            return clean
        }
        return sanitized(defaultURLString) ?? productionURLString
    }

    static var baseURL: URL {
        // Safe: `baseURLString` only ever returns a string that already parsed in `sanitized`.
        URL(string: baseURLString)!
    }

    static var isOverridden: Bool {
        UserDefaults.standard.string(forKey: overrideKey) != nil
    }

    /// Returns a normalised absolute URL string, or nil if the input can't be one.
    /// Accepts a bare host ("192.168.1.5:5235") for typing convenience on a phone keyboard.
    static func sanitized(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return s
    }

    /// Persist a new host. Returns false (and changes nothing) if the input isn't usable.
    ///
    /// Callers are responsible for signing out afterwards — a JWT is only valid against the
    /// server that minted it (prod and dev sign with different secrets), so carrying credentials
    /// across a switch produces 401s that look like an auth bug rather than a wrong host.
    @discardableResult
    static func setBaseURLString(_ raw: String) -> Bool {
        guard let clean = sanitized(raw) else { return false }
        guard clean != baseURLString else { return true }
        UserDefaults.standard.set(clean, forKey: overrideKey)
        return true
    }

    static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: overrideKey)
    }

    #else

    static var baseURLString: String { productionURLString }
    static var baseURL: URL { URL(string: productionURLString)! }

    #endif
}
