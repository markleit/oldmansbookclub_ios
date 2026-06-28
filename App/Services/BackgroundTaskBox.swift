import UIKit

/// Keeps the app running for a short window after it's backgrounded so an in-flight
/// piece of work can finish instead of being suspended mid-flight. iOS grants roughly
/// 30 seconds; if it needs to reclaim sooner, the expiration handler ends the task.
///
/// Used to wrap a media send (blob upload + SignalR invoke) so that locking/backgrounding
/// the phone right after hitting send doesn't strand the message (#70/#72). Anything that
/// outlives the window is still covered by the persisted MediaSendQueue + resume flush.
///
/// Begin on init, call `end()` when the work completes (a `defer` is the natural spot).
/// `end()` is idempotent, so the completion path and the expiration handler can both call it.
@MainActor
final class BackgroundTaskBox {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
