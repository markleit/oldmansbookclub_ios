import Foundation

// #178 — state the app shares with its Share extension. Compiled into BOTH targets.
//
// - App Group: small UserDefaults suite for values the extension can't otherwise see (the app's
//   own UserDefaults.standard is private to it): the DEBUG server-host override and this device's
//   APNs token.
// - Keychain: the JWT stays exactly where TokenStore has always written it — the app's default
//   keychain group, which is its own App ID. Both targets list that App ID in
//   keychain-access-groups, so the extension reads the existing item with no migration.
//
// Both identifiers come from Info.plist (expanded from build settings) so the .dev app and its
// extension get their own group and never touch the App Store app's.
enum SharedContainer {
    static var appGroupId: String? {
        Bundle.main.object(forInfoDictionaryKey: "OMBCAppGroup") as? String
    }

    static var keychainAccessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "OMBCKeychainGroup") as? String
    }

    static var defaults: UserDefaults? {
        appGroupId.flatMap { UserDefaults(suiteName: $0) }
    }

    enum Key {
        static let debugServerBaseURL = "debugServerBaseURL"
        static let deviceToken = "apns_device_token"
    }

    /// Same service/account TokenStore writes (TokenStore.keychainService / keychainTokenAccount).
    static let keychainService = "com.example.oldmansbookclub"
    static let keychainTokenAccount = "jwt_token"
}
