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
        // Subscribe to MetricKit early so crash/hang diagnostics from the previous run are
        // delivered and auto-filed as GitHub issues (#100). Device-only; no-op in the simulator.
        DiagnosticsReporter.shared.start()
        // Recreate the background upload session so any task that finished while the app was
        // suspended/killed delivers its completion (marks the queue item uploaded).
        BackgroundUploadService.shared.activate()
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

    // A new-message push (content-available:1) woke us in the background. Prefetch the message
    // into the chat cache so opening that chat is instant, then report the result so iOS keeps
    // scheduling our wakes. Best-effort — iOS throttles background execution.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let bookIdStr = userInfo["bookId"] as? String,
              let bookId = UUID(uuidString: bookIdStr) else {
            completionHandler(.noData)
            return
        }
        // Message pushes carry BOTH an alert and content-available:1, so in the foreground this
        // handler fires ALONGSIDE willPresent — bumping here too would double-count (#96). Only
        // bump from here when we're actually in the background, where willPresent doesn't fire.
        let inBackground = application.applicationState == .background
        Task {
            // Live-update the Library badge for a book you're not viewing (#96): a new-message
            // push is the only signal for a non-open book, so bump its unread count optimistically
            // (the next LibraryViewModel.load() → seed() reconciles to server truth).
            if inBackground, await ChatService.shared.activeBookId != bookId {
                await bumpUnread(bookId: bookId)
            }
            let gotNewData = await MessagePrefetcher.shared.prefetch(bookId: bookId)
            completionHandler(gotNewData ? .newData : .noData)
        }
    }

    // Optimistically increment a book's unread count on a delivered message push, so Library
    // badges move live instead of only on pull-to-refresh / foreground (#96). Guarded to signed-in
    // only; the caller skips the currently-open book (it owns its own count while on screen, #87).
    // seed() heals any drift on the next load, so an occasional over/under-count self-corrects.
    @MainActor
    private func bumpUnread(bookId: UUID) {
        guard TokenStore.shared.token != nil else { return }
        UnreadStore.shared.bump(bookId: bookId, by: 1)
    }

    // The system relaunched us (or woke us) to finish delivering background upload events.
    // Hand the completion handler to the service; it's called once all events are delivered.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundUploadService.shared.setBackgroundCompletionHandler(completionHandler, for: identifier)
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task {
            // Retry a few times so a transient network blip doesn't leave the server with a stale
            // token until the next foreground (#25).
            for attempt in 0..<3 {
                do { try await APIClient.shared.registerDevice(token: token); return }
                catch {
                    if attempt == 2 { return }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
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
            let isOpen = await ChatService.shared.activeBookId == bookId
            completionHandler(isOpen ? [] : [.banner, .list, .sound, .badge])
            // Foreground push for a book you're not viewing → move its Library badge live (#96).
            if !isOpen { await bumpUnread(bookId: bookId) }
        }
    }
}
