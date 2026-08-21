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
    // Dismissing the "notifications off" banner snoozes it; it reappears after this
    // interval if notifications are still off — a periodic reminder, not a constant band. (#25)
    @AppStorage("notifBannerSnoozedUntil") private var notifBannerSnoozedUntil: Double = 0
    private let notifBannerSnoozeInterval: TimeInterval = 14 * 24 * 60 * 60  // 2 weeks

    private var showNotificationsBanner: Bool {
        notificationsDenied && Date().timeIntervalSince1970 >= notifBannerSnoozedUntil
    }

    var body: some View {
        Group {
            if auth.isAuthenticated {
                ContentView()
                    .overlay(alignment: .top) {
                        if showNotificationsBanner {
                            NotificationsOffBanner {
                                withAnimation {
                                    notifBannerSnoozedUntil = Date().addingTimeInterval(notifBannerSnoozeInterval).timeIntervalSince1970
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.top, 4)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
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
                            // Retry any read/heard receipt that never reached the server (#119) —
                            // until it does, this device's unread count and the server's disagree.
                            Task { await ReceiptQueue.shared.flush() }
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
// new-message alerts (the "Jeffrey" case). "Turn On" opens Settings; "✕" snoozes it (reminder,
// not a permanent band); returning to the app re-checks status. (#25)
struct NotificationsOffBanner: View {
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.slash.fill")
                .font(.footnote)
            Text("Notifications are off — you won't get new-message alerts.")
                .font(.footnote)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 6)
            Button("Turn On") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.footnote.weight(.semibold))
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss reminder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        // Floating card: opaque material so content underneath doesn't bleed through,
        // orange tint for the warning, rounded corners + shadow so it reads as a toast.
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.orange.opacity(0.18))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}
