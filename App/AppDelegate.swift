import UIKit
import UserNotifications

final class DeepLinkCoordinator: ObservableObject {
    static let shared = DeepLinkCoordinator()
    private init() {}
    @Published var pendingBookId: UUID?
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Cold launch: notification payload is in launchOptions before any view exists
        if let notification = launchOptions?[.remoteNotification] as? [String: Any],
           let bookIdStr = notification["bookId"] as? String,
           let bookId = UUID(uuidString: bookIdStr) {
            DeepLinkCoordinator.shared.pendingBookId = bookId
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task {
            try? await APIClient.shared.registerDevice(token: token)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {}

    // Called when user taps a notification
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let bookIdStr = userInfo["bookId"] as? String, let bookId = UUID(uuidString: bookIdStr) {
            DispatchQueue.main.async {
                DeepLinkCoordinator.shared.pendingBookId = bookId
            }
        }
        completionHandler()
    }

    // Show notifications as banners while app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
