import SwiftUI

struct SettingsView: View {
    @AppStorage("tapToTalkEnabled") private var tapToTalk = false

    var body: some View {
        Form {
            Section(footer: Text("When off, hold the mic button to record and release to send.")) {
                Toggle("Tap-to-Talk", isOn: $tapToTalk)
            }

            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    Text("About")
                }
            }
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
