import UIKit
import UserNotifications

final class DeepLinkCoordinator: ObservableObject {
    static let shared = DeepLinkCoordinator()
    private init() {}
    @Published var pendingBookId: UUID?
    // The specific message the tapped notification was for. Published so an
    // already-open chat view (where .task(id:) won't re-fire) still reacts.
    // pendingMessageBookId records which book it belongs to, so a chat only
    // adopts a target meant for it.
    @Published var pendingMessageId: UUID?
    var pendingMessageBookId: UUID?
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
            let mid = (notification["messageId"] as? String).flatMap(UUID.init)
            DeepLinkCoordinator.shared.pendingMessageBookId = mid != nil ? bookId : nil
            DeepLinkCoordinator.shared.pendingMessageId = mid
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
            let mid = (userInfo["messageId"] as? String).flatMap(UUID.init)
            DeepLinkCoordinator.shared.pendingMessageBookId = mid != nil ? bookId : nil
            DeepLinkCoordinator.shared.pendingMessageId = mid
            DeepLinkCoordinator.shared.pendingBookId = bookId
        }
        completionHandler()
    }

    // Suppress notification if the user is already viewing that chat; show for all others
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        guard let bookIdStr = userInfo["bookId"] as? String,
              let bookId = UUID(uuidString: bookIdStr) else {
            completionHandler([.banner, .list, .sound, .badge])
            return
        }
        Task {
            let active = await ChatService.shared.activeBookId
            completionHandler(active == bookId ? [] : [.banner, .list, .sound, .badge])
        }
    }
}
