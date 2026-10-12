import UIKit
import UserNotifications

/// When the force-quit reminder fires, and what it says.
struct ReminderPlan: Equatable {
    let fireAt: Date
    let count: Int
}

/// #204 PR 7 — the one case sending in the background can't cover: an app swiped away can't send
/// until it's opened (an iOS rule). A local notification 10 minutes after the oldest unsent
/// message says so. It moves as messages send, is cancelled (and cleared) when nothing's left, and
/// isn't shown while the app is open — the bubbles say it already.
enum SendReminder {
    static let identifier = "ombc.unsent-reminder"
    /// Never sooner than this: an overdue reminder (the app was open past it) is re-armed this far
    /// out when the app leaves the foreground.
    static let minimumLead: TimeInterval = 60

    /// What the reminder is about: the oldest message that will still send, and how many there are.
    /// Refused messages don't count — they won't go however long the app is open.
    struct Basis: Equatable {
        let oldest: Date
        let count: Int
    }

    static func basis(for items: [SendItem]) -> Basis? {
        // A video whose upload has landed is the server's to create (design v2): not unsent.
        let unsent = items.filter { $0.status != .refused && $0.serverCreates != true }
        guard let oldest = unsent.map(\.sentAt).min() else { return nil }
        return Basis(oldest: oldest, count: unsent.count)
    }

    static func plan(_ basis: Basis, after delay: TimeInterval, now: Date) -> ReminderPlan {
        ReminderPlan(fireAt: max(basis.oldest.addingTimeInterval(delay), now.addingTimeInterval(minimumLead)),
                     count: basis.count)
    }

    static func text(count: Int) -> String {
        count == 1
            ? "1 message waiting to send — it'll go automatically when you're online. If you closed the app, open it to finish."
            : "\(count) messages waiting to send — they'll go automatically when you're online. If you closed the app, open it to finish."
    }

    /// How a notification shows while the app is open: the reminder not at all; nil for others.
    static func foregroundOptions(for identifier: String) -> UNNotificationPresentationOptions? {
        identifier == Self.identifier ? [] : nil
    }

    /// Replaces the pending reminder with `plan`, or removes it (and one already shown) when nil.
    static func apply(_ plan: ReminderPlan?) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard let plan else {
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            return
        }
        let content = UNMutableNotificationContent()
        content.body = text(count: plan.count)
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, plan.fireAt.timeIntervalSinceNow),
                                                        repeats: false)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}
