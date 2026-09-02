import Foundation
import SwiftUI

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

    /// The dev Mac's LAN address, for a physical device pointed at a local `dotnet run`
    /// (`ipconfig getifaddr en0`). Update this whenever the network changes — it's a preset for
    /// convenience, not a source of truth.
    static let devMachineURLString = "http://10.24.1.83:5235"

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

#if DEBUG
// Shared by SettingsView (signed in) and LoginView (pre-auth — a fresh device install defaults
// to production, which has no dev-login, so this is the ONLY route to a local server before
// authenticating). Deliberately not Form/Section-specific so it drops into either a Form or a
// plain VStack: a Form gives each child its own row; a VStack doesn't, which is what LoginView
// wants since it isn't a list screen.
struct DebugServerControl: View {
    /// Called after a host is actually applied — e.g. to sign out, since a token is only valid
    /// on the server that issued it. Not called for a no-op apply (draft already matched).
    var onApply: () -> Void = {}

    @State private var draft = ServerEnvironment.baseURLString
    @State private var invalid = false

    private var pending: Bool {
        guard let clean = ServerEnvironment.sanitized(draft) else { return false }
        if clean != ServerEnvironment.baseURLString { return true }
        // Same host, but stored as an explicit override while it happens to equal the build
        // default — applying still has work to do: clear the key so the build default resumes
        // being followed if it ever changes.
        return clean == ServerEnvironment.sanitized(ServerEnvironment.defaultURLString)
            && ServerEnvironment.isOverridden
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Host")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("192.168.1.5:5235", text: $draft)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.body.monospaced())
        }
        .padding(.vertical, 2)

        // Only while the draft differs — otherwise it just repeats the field above. When it does
        // appear it answers the question that actually matters mid-edit: what is the app still
        // talking to until I hit Apply?
        if pending {
            LabeledContent("Still live", value: ServerEnvironment.baseURLString)
                .font(.footnote)
                .foregroundColor(.secondary)
        }

        // Only two presets are ever meaningful: the build default is always equal to one of them
        // (localhost on simulator, production on device), so a third "Default" button would
        // duplicate whichever one it matched. Selecting the default is handled in apply()
        // instead, by clearing the override rather than pinning it.
        HStack(spacing: 20) {
            // .borderless is load-bearing: two Buttons in one Form row otherwise resolve as a
            // single row-wide tap target and neither action fires.
            Button("Production") { draft = ServerEnvironment.productionURLString }
                .buttonStyle(.borderless)
            Button("Localhost") { draft = ServerEnvironment.localhostURLString }
                .buttonStyle(.borderless)
            // Only useful from a physical device — localhost on a device means the device
            // itself, not the Mac. Harmless to show on the simulator too; it just duplicates
            // Localhost there.
            Button("Dev Machine") { draft = ServerEnvironment.devMachineURLString }
                .buttonStyle(.borderless)
            Spacer()
            if ServerEnvironment.isOverridden {
                Text("overridden")
                    .foregroundColor(.secondary)
            }
        }
        .font(.footnote)

        Button("Apply", action: apply)
            .disabled(!pending)

        Text(invalid
             ? "Not a valid host — expected something like 192.168.1.5:5235."
             : "A token is only valid on the server that issued it, so applying a new host signs you out if needed. Release builds always use production.")
        .font(.footnote)
        .foregroundColor(invalid ? .red : .secondary)
    }

    private func apply() {
        guard let clean = ServerEnvironment.sanitized(draft) else {
            invalid = true
            return
        }
        invalid = false
        let changed = clean != ServerEnvironment.baseURLString
        // Choosing the build default CLEARS the override rather than writing it. Storing it would
        // silently pin this build to today's default, so a later change to the default (or moving
        // the same install between simulator and device) would no longer be followed.
        if clean == ServerEnvironment.sanitized(ServerEnvironment.defaultURLString) {
            ServerEnvironment.resetToDefault()
        } else {
            ServerEnvironment.setBaseURLString(clean)
        }
        draft = ServerEnvironment.baseURLString
        if changed { onApply() }
    }
}
#endif
