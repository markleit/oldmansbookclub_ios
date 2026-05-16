import SwiftUI
import UserNotifications

@main
struct OldMansBookClubApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var auth = AuthViewModel()

    init() {
        URLCache.shared = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var auth: AuthViewModel
    @AppStorage("hasAcceptedEULA_v2") private var hasAcceptedEULA = false

    var body: some View {
        Group {
            if auth.isAuthenticated {
                ContentView()
                    .task { await requestPushPermission() }
            } else {
                LoginView()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { !hasAcceptedEULA },
            set: { if !$0 { hasAcceptedEULA = true } }
        )) {
            EULAView { hasAcceptedEULA = true }
        }
    }

    private func requestPushPermission() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted {
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }
}
