import Foundation
import os
import UIKit

// #203 — one line per step of every send (queued → upload link → upload → post → done/failed,
// plus what triggered each retry pass and the app's foreground/background transitions), so
// "my message didn't send" can be answered from evidence instead of reconstructed from code
// and blob timestamps.
//
// Written two places:
// - the unified log at `.notice` (persists for days; `.info` is memory-only) — for a phone on
//   this Mac: `log show <archive> --predicate 'subsystem == "com.markleit.oldmansbookclub"
//   AND category == "send"'`;
// - a small rolling file in the app's own container, attached automatically to in-app Feedback
//   (FeedbackView) — the only practical way to get the trail from anyone else's phone. iOS only
//   lets an app read its *current* run's unified log, and a stuck send usually spans a relaunch.
//
// Feedback lands in a public GitHub repo, so lines carry only times, 8-char ids, message kinds,
// states and error codes — never message text or names.
enum SendLog {
    private static let logger = Logger(subsystem: "com.markleit.oldmansbookclub", category: "send")
    private static let queue = DispatchQueue(label: "SendLog.file", qos: .utility)
    private static let maxLines = 500
    nonisolated(unsafe) private static var lines: [String]?   // only touched on `queue`
    @MainActor private static var observers: [NSObjectProtocol] = []

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("send_log.txt")
    }

    private static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Call once at launch: records the launch and app lifecycle transitions, so a send's trail
    /// shows when the app was backgrounded or reopened around it.
    @MainActor
    static func start() {
        guard observers.isEmpty else { return }
        note(UIApplication.shared.applicationState == .background ? "app launch (background)" : "app launch")
        let events: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "app active"),
            (UIApplication.didEnterBackgroundNotification, "app background"),
        ]
        observers = events.map { name, label in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in note(label) }
        }
    }

    static func note(_ event: String, _ id: UUID? = nil, _ detail: String = "") {
        let short = id.map { String($0.uuidString.prefix(8)) } ?? "-"
        logger.notice("\(event, privacy: .public) [\(short, privacy: .public)] \(detail, privacy: .public)")
        let line = "\(timestamp.string(from: Date())) \(event) [\(short)]\(detail.isEmpty ? "" : " " + detail)"
        queue.async { append(line) }
    }

    /// The most recent lines (oldest first), for attaching to a Feedback report.
    static func recent(limit: Int = 300) -> String {
        queue.sync {
            loadIfNeeded()
            return (lines ?? []).suffix(limit).joined(separator: "\n")
        }
    }

    /// A compact, loggable description of a send failure.
    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError { return "URLError \(urlError.code.rawValue)" }
        return String(describing: error)
    }

    // MARK: - File (on `queue`)

    private static func loadIfNeeded() {
        guard lines == nil else { return }
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        lines = text.split(separator: "\n").map(String.init)
    }

    private static func append(_ line: String) {
        loadIfNeeded()
        lines?.append(line)
        if let count = lines?.count, count > maxLines { lines?.removeFirst(count - maxLines) }
        try? (lines ?? []).joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
