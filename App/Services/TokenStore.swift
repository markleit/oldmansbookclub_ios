import Foundation

final class TokenStore {
    static let shared = TokenStore()

    private let tokenKey = "jwt_token"
    private let userIdKey = "user_id"
    private let userNameKey = "user_name"
    private let clubIdKey = "club_id"

    private init() {}

    var token: String? {
        get { UserDefaults.standard.string(forKey: tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: tokenKey) }
    }

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

    var clubId: UUID? {
        get {
            guard let str = UserDefaults.standard.string(forKey: clubIdKey) else { return nil }
            return UUID(uuidString: str)
        }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: clubIdKey) }
    }

    var isAuthenticated: Bool { token != nil }

    func save(token: String, userId: UUID, displayName: String) {
        self.token = token
        self.userId = userId
        self.displayName = displayName
    }

    func clear() {
        token = nil
        userId = nil
        displayName = nil
        clubId = nil
    }
}
