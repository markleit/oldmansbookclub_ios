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
    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationsDenied = false

    var body: some View {
        Group {
            if auth.isAuthenticated {
                ContentView()
                    .safeAreaInset(edge: .top) {
                        if notificationsDenied { NotificationsOffBanner() }
                    }
                    .task { await ensurePushRegistration() }
                    .onChange(of: scenePhase) { phase in
                        if phase == .active {
                            // Re-register the push token on every foreground so a token that
                            // changed (reinstall / build swap) reaches the server promptly, and
                            // re-check whether notifications were turned off in Settings (#25).
                            Task { await ensurePushRegistration() }
                            Task { await refreshMyProfile() }
                            // Get pending blob uploads moving on every foreground (and first
                            // launch), regardless of which screen is open — the bytes upload
                            // in the background; the send completes when the chat connects.
                            Task { await BackgroundUploadService.shared.resumePendingUploads() }
                        }
                    }
            } else if let clubName = auth.pendingApprovalClubName {
                PendingApprovalView(clubName: clubName, declined: false)
            } else if let clubName = auth.declinedClubName {
                PendingApprovalView(clubName: clubName, declined: true)
            } else if auth.needsClubSetup {
                ClubSetupView()
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

    private func refreshMyProfile() async {
        guard let me = try? await APIClient.shared.getMe() else { return }
        TokenStore.shared.isAdmin = me.isAdmin
        TokenStore.shared.isClubAdmin = me.isClubAdmin
        TokenStore.shared.displayName = me.displayName
    }

    // Runs on launch AND every foreground. First time it asks for permission; if already
    // authorized it re-registers so the CURRENT APNs token is pushed to the server (closing the
    // stale-token window after a reinstall/build swap); if denied it flags the banner so the user
    // knows they're silently missing alerts. (#25)
    private func ensurePushRegistration() async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            await MainActor.run {
                notificationsDenied = !granted
                if granted { UIApplication.shared.registerForRemoteNotifications() }
            }
        case .authorized, .provisional, .ephemeral:
            await MainActor.run {
                notificationsDenied = false
                UIApplication.shared.registerForRemoteNotifications()
            }
        case .denied:
            await MainActor.run { notificationsDenied = true }
        @unknown default:
            break
        }
    }
}

// Shown when notifications are turned off in Settings — otherwise the user silently gets no
// new-message alerts (the "Jeffrey" case). Tapping opens Settings; returning re-checks status.
struct NotificationsOffBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.slash.fill")
            Text("Notifications are off — you won't be alerted to new messages.")
                .font(.footnote)
            Spacer(minLength: 8)
            Button("Turn On") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.16))
    }
}
