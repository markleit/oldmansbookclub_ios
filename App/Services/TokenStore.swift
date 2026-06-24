import Foundation
import Security

final class TokenStore {
    static let shared = TokenStore()

    private let keychainService = "com.example.oldmansbookclub"
    private let keychainTokenAccount = "jwt_token"
    private let keychainRefreshAccount = "refresh_token"

    private let userIdKey = "user_id"
    private let userNameKey = "user_name"
    private let clubIdKey = "club_id"
    private let clubNameKey = "club_name"
    private let nicknameKey = "user_nickname"
    private let avatarUrlKey = "user_avatar_url"
    private let isAdminKey = "user_is_admin"
    private let isClubAdminKey = "user_is_club_admin"

    private init() {
        // Migrate any existing UserDefaults token into Keychain on first run
        if let legacy = UserDefaults.standard.string(forKey: "jwt_token"), token == nil {
            token = legacy
            UserDefaults.standard.removeObject(forKey: "jwt_token")
        }
    }

    // MARK: - Token (Keychain)

    var token: String? {
        get { keychainRead(account: keychainTokenAccount) }
        set { keychainWrite(account: keychainTokenAccount, value: newValue) }
    }

    var refreshToken: String? {
        get { keychainRead(account: keychainRefreshAccount) }
        set { keychainWrite(account: keychainRefreshAccount, value: newValue) }
    }

    private func keychainRead(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainWrite(account: String, value: String?) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account
        ]
        if let value, let data = value.data(using: .utf8) {
            // AfterFirstUnlock so the token is readable while the device is locked (after the
            // first unlock since boot) — e.g. CarPlay running in the background with the phone
            // in your pocket. The default (WhenUnlocked) returns nil there, which made the app
            // think the session was invalid and wipe the (still-valid) tokens → spurious logout.
            let attributes: [CFString: Any] = [
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
            ]
            if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
                var add = query
                add[kSecValueData] = data
                add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
                SecItemAdd(add as CFDictionary, nil)
            }
        } else {
            SecItemDelete(query as CFDictionary)
        }
    }

    // MARK: - Non-sensitive fields (UserDefaults)

    var userId: UUID? {
        get {
            guard let str = UserDefaults.standard.string(forKey: userIdKey) else { return nil }
            return UUID(uuidString: str)
        }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: userIdKey) }
    }

    var displayName: String? {
        get { UserDefaults.standard.string(forKey: userNameKey) }
        set { UserDefaults.standard.set(newValue, forKey: userNameKey) }
    }

    var nickname: String? {
        get { UserDefaults.standard.string(forKey: nicknameKey) }
        set { UserDefaults.standard.set(newValue, forKey: nicknameKey) }
    }

    var avatarUrl: String? {
        get { UserDefaults.standard.string(forKey: avatarUrlKey) }
        set { UserDefaults.standard.set(newValue, forKey: avatarUrlKey) }
    }

    var clubId: UUID? {
        get {
            guard let str = UserDefaults.standard.string(forKey: clubIdKey) else { return nil }
            return UUID(uuidString: str)
        }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: clubIdKey) }
    }

    var clubName: String? {
        get { UserDefaults.standard.string(forKey: clubNameKey) }
        set { UserDefaults.standard.set(newValue, forKey: clubNameKey) }
    }

    var isAdmin: Bool {
        get { UserDefaults.standard.bool(forKey: isAdminKey) }
        set { UserDefaults.standard.set(newValue, forKey: isAdminKey) }
    }

    var isClubAdmin: Bool {
        get { UserDefaults.standard.bool(forKey: isClubAdminKey) }
        set { UserDefaults.standard.set(newValue, forKey: isClubAdminKey) }
    }

    var isAuthenticated: Bool { token != nil }

    var isTokenExpired: Bool {
        guard let token else { return false }
        let parts = token.components(separatedBy: ".")
        guard parts.count == 3 else { return true }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else { return true }
        return Date(timeIntervalSince1970: exp) < Date()
    }

    func save(token: String, refreshToken: String?, userId: UUID, displayName: String, nickname: String? = nil, avatarUrl: String? = nil, isAdmin: Bool = false, isClubAdmin: Bool = false) {
        self.token = token
        self.refreshToken = refreshToken
        self.userId = userId
        self.displayName = displayName
        self.nickname = nickname
        self.avatarUrl = avatarUrl
        self.isAdmin = isAdmin
        self.isClubAdmin = isClubAdmin
    }

    func clear() {
        token = nil
        refreshToken = nil
        userId = nil
        // displayName intentionally kept — Apple only sends it on first auth,
        // so we preserve it as a fallback for re-login on the same device
        clubId = nil
        clubName = nil
        nickname = nil
        avatarUrl = nil
        isAdmin = false
        isClubAdmin = false
    }
}
