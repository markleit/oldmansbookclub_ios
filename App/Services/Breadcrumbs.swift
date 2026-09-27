import UIKit

// Watchdog crashes #175–#177: the full device logs showed a UIKit layout loop with only system
// frames on the main thread, so neither they nor the MetricKit report could say which screen was
// up. MetricKit delivers a report on a LATER launch, so "the current screen" at report time is the
// wrong session's. Instead, keep a short trail of screen + lifecycle events per process, keyed by
// pid; DiagnosticsReporter looks up the crashed process's trail via MXMetaData.pid (iOS 17+).
//
// Stored in UserDefaults (written out of process by cfprefsd, so a trail recorded before a freeze
// survives the watchdog kill). Small by construction: ≤ maxEvents per process, ≤ maxProcesses.
enum Breadcrumbs {
    private static let key = "diagnosticBreadcrumbs"
    private static let maxEvents = 15
    private static let maxProcesses = 10
    private static let pid = ProcessInfo.processInfo.processIdentifier
    private static let launchedAt = Date()
    @MainActor private static var observers: [NSObjectProtocol] = []

    /// Call once, early in launch: pins the launch time and records app lifecycle transitions.
    @MainActor
    static func start() {
        guard observers.isEmpty else { return }
        let background = UIApplication.shared.applicationState == .background
        record(background ? "launch (in background)" : "launch")
        let events: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "active"),
            (UIApplication.willResignActiveNotification, "resign active"),
            (UIApplication.didEnterBackgroundNotification, "background"),
            (UIApplication.willEnterForegroundNotification, "foreground"),
        ]
        observers = events.map { name, label in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                record(label)
            }
        }
    }

    /// Append an event (a screen, a tab, a lifecycle change) to this process's trail.
    static func record(_ event: String) {
        let defaults = UserDefaults.standard
        var all = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        let me = String(pid)
        // Element 0 is the launch epoch — used to evict the oldest processes, not shown.
        var trail = all[me] ?? [String(Int(launchedAt.timeIntervalSince1970))]
        trail.append("+\(Int(Date().timeIntervalSince(launchedAt)))s \(event)")
        if trail.count > maxEvents + 1 { trail.removeSubrange(1...(trail.count - maxEvents - 1)) }
        all[me] = trail
        if all.count > maxProcesses {
            let oldest = all.sorted { (Int($0.value.first ?? "") ?? 0) < (Int($1.value.first ?? "") ?? 0) }
            for (pid, _) in oldest.prefix(all.count - maxProcesses) { all[pid] = nil }
        }
        defaults.set(all, forKey: key)
    }

    /// The recorded trail for a (usually earlier, crashed) process, oldest event first.
    static func trail(forPid pid: Int32) -> String? {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        guard let trail = all[String(pid)], trail.count > 1 else { return nil }
        return trail.dropFirst().joined(separator: " → ")
    }
}
