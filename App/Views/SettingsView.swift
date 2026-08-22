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
//
// Signed-in-only wrapper around DebugServerControl (see LoginView.swift), which is the
// pre-auth copy — Settings is unreachable before signing in, and a fresh device install
// defaults to production, where dev-login 404s. Without that copy there is no route to a
// local server at all on a first launch.
private struct ServerEnvironmentSection: View {
    @EnvironmentObject var auth: AuthViewModel

    var body: some View {
        Section {
            DebugServerControl {
                // Drop the refresh token BEFORE signing out. signOut() otherwise fires a
                // fire-and-forget revoke, which — now that the host has already changed —
                // would hand the old server's refresh token to the new one.
                TokenStore.shared.refreshToken = nil
                auth.signOut()
            }
        } header: {
            Text("Server (Debug)")
        }
    }
}
#endif
