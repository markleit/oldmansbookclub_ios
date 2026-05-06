import Foundation
import Security

final class TokenStore {
    static let shared = TokenStore()

    private let keychainService = "com.example.oldmansbookclub"
    private let keychainTokenAccount = "jwt_token"

    private let userIdKey = "user_id"
    private let userNameKey = "user_name"
    private let clubIdKey = "club_id"
    private let nicknameKey = "user_nickname"
    private let avatarUrlKey = "user_avatar_url"

    private init() {
        // Migrate any existing UserDefaults token into Keychain on first run
        if let legacy = UserDefaults.standard.string(forKey: "jwt_token"), keychainToken == nil {
            keychainToken = legacy
            UserDefaults.standard.removeObject(forKey: "jwt_token")
        }
    }

    // MARK: - Token (Keychain)

    var token: String? {
        get { keychainToken }
        set { keychainToken = newValue }
    }

    private var keychainToken: String? {
        get {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: keychainService,
                kSecAttrAccount: keychainTokenAccount,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            if let value = newValue, let data = value.data(using: .utf8) {
                let query: [CFString: Any] = [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: keychainService,
                    kSecAttrAccount: keychainTokenAccount
                ]
                let attributes: [CFString: Any] = [kSecValueData: data]
                if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
                    var add = query
                    add[kSecValueData] = data
                    SecItemAdd(add as CFDictionary, nil)
                }
            } else {
                let query: [CFString: Any] = [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: keychainService,
                    kSecAttrAccount: keychainTokenAccount
                ]
                SecItemDelete(query as CFDictionary)
            }
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

    var isAuthenticated: Bool { token != nil }

    func save(token: String, userId: UUID, displayName: String, nickname: String? = nil, avatarUrl: String? = nil) {
        self.token = token
        self.userId = userId
        self.displayName = displayName
        self.nickname = nickname
        self.avatarUrl = avatarUrl
    }

    func clear() {
        token = nil
        userId = nil
        displayName = nil
        clubId = nil
        nickname = nil
        avatarUrl = nil
    }
}
