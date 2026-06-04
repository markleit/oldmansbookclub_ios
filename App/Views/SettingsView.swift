import SwiftUI

struct SettingsView: View {
    @AppStorage("tapToTalkEnabled") private var tapToTalk = false

    var body: some View {
        Form {
            Section(footer: Text("When off, hold the mic button to record and release to send.")) {
                Toggle("Tap-to-Talk", isOn: $tapToTalk)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: tapToTalk) { newValue in
            Task { try? await APIClient.shared.updateProfile(displayName: nil, nickname: nil, avatarUrl: nil, tapToTalk: newValue) }
        }
    }
}
