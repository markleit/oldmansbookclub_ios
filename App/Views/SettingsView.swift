import SwiftUI

struct SettingsView: View {
    @AppStorage("tapToTalkEnabled") private var tapToTalk = false
    // Local-only (device audio feedback). Default on. Read in AudioCue via the same key.
    @AppStorage("micChirpEnabled") private var micChirp = true

    var body: some View {
        Form {
            Section(footer: Text("When off, hold the mic button to record and release to send.")) {
                Toggle("Tap-to-Talk", isOn: $tapToTalk)
            }

            Section(footer: Text("Play a short tone when a voice recording starts and stops.")) {
                Toggle("Recording Tones", isOn: $micChirp)
            }

            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    Text("About")
                }
            }

            #if DEBUG
            ServerEnvironmentSection()
            #endif
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: tapToTalk) { newValue in
            Task { try? await APIClient.shared.updateProfile(displayName: nil, nickname: nil, avatarUrl: nil, tapToTalk: newValue) }
        }
    }
}

struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
                LabeledContent("Build", value: build)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
// Point a build at a laptop or a staging slot (#120). DEBUG-only: a Release build has no such
// section and no runtime host at all, so nothing here can reach a shipped app.
private struct ServerEnvironmentSection: View {
    @EnvironmentObject var auth: AuthViewModel
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
        Section {
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

            // Only while the draft differs — otherwise it just repeats the field above. When it
            // does appear it answers the question that actually matters mid-edit: what is the app
            // still talking to until I hit Apply?
            if pending {
                LabeledContent("Still live", value: ServerEnvironment.baseURLString)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            // Only two presets are ever meaningful: the build default is always equal to one of
            // them (localhost on simulator, production on device), so a third "Default" button
            // would duplicate whichever one it matched. Selecting the default is handled in
            // apply() instead, by clearing the override rather than pinning it.
            HStack(spacing: 20) {
                // .borderless is load-bearing: two Buttons in one Form row otherwise resolve as a
                // single row-wide tap target and neither action fires.
                Button("Production") { draft = ServerEnvironment.productionURLString }
                    .buttonStyle(.borderless)
                Button("Localhost") { draft = ServerEnvironment.localhostURLString }
                    .buttonStyle(.borderless)
                Spacer()
                if ServerEnvironment.isOverridden {
                    Text("overridden")
                        .foregroundColor(.secondary)
                }
            }
            .font(.footnote)

            Button("Apply & Sign Out", action: apply)
                .disabled(!pending)
        } header: {
            Text("Server (Debug)")
        } footer: {
            Text(invalid
                 ? "Not a valid host — expected something like 192.168.1.5:5235."
                 : "Switching signs you out: a token is only valid on the server that issued it, so keeping it would produce 401s that look like an auth bug. Release builds always use production.")
            .foregroundColor(invalid ? .red : .secondary)
        }
    }

    private func apply() {
        guard let clean = ServerEnvironment.sanitized(draft) else {
            invalid = true
            return
        }
        invalid = false
        // Choosing the build default CLEARS the override rather than writing it. Storing it would
        // silently pin this build to today's default, so a later change to the default (or moving
        // the same install between simulator and device) would no longer be followed.
        if clean == ServerEnvironment.sanitized(ServerEnvironment.defaultURLString) {
            ServerEnvironment.resetToDefault()
        } else {
            ServerEnvironment.setBaseURLString(clean)
        }
        draft = ServerEnvironment.baseURLString
        // Drop the refresh token BEFORE signing out. signOut() otherwise fires a fire-and-forget
        // revoke, which — now that the host has already changed — would hand the old server's
        // refresh token to the new one. Clearing it first makes signOut() purely local.
        TokenStore.shared.refreshToken = nil
        auth.signOut()
    }
}
#endif
