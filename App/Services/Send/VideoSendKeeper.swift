import BackgroundTasks
import Foundation

/// What the engine tells the keeper about one video's work (#204 design v2).
enum VideoWork: Equatable {
    /// The user tapped Send on a video, with the app in front: ask iOS to keep its work going.
    case start(UUID)
    /// How far along it is, 0–1: compressing, reserving, uploading.
    case progress(UUID, Double)
    /// Its work is over: uploaded (or sent) — or stopped, to be picked up the next time the app runs.
    case finish(UUID, success: Bool)
}

// #204 design v2 — keeps a video's send going after the user leaves the app, on iOS 26+: compressing
// it, reserving its message and uploading it. iOS's continued processing (BGContinuedProcessingTask)
// shows its own "Sending video" progress, which the user can cancel, and lets the app run until the
// work is done.
//
// A speed-up, never the guarantee (research on #204, 2026-10-12). iOS can end it at any moment: it
// stalls on a locked phone (Apple Feedback FB19916760), it's cancelled with the app from the
// switcher, and work that shows no progress for about 30 s is expired. When it ends early the video
// is still in the outbox — compression starts again the next time the app runs, and the reminder
// covers the gap. Older iOS: the usual ~30 s after leaving.
//
// Started at the tap: Apple allows it only in response to the user's action, with the app in front.
@MainActor
final class VideoSendKeeper {
    static let shared = VideoSendKeeper()

    /// Info.plist's BGTaskSchedulerPermittedIdentifiers lists "<bundle id>.send-video.*".
    static var identifierPrefix: String { (Bundle.main.bundleIdentifier ?? "com.markleit.oldmansbookclub") + ".send-video." }

    /// iOS ended one early (expired, or the user cancelled it): stop that video's work for now.
    var onEnded: ((UUID) -> Void)?

    /// Running tasks (BGContinuedProcessingTask — typed Any so this compiles for iOS 16).
    private var running: [UUID: Any] = [:]
    private var progress: [UUID: Double] = [:]
    private var finished: Set<UUID> = []
    /// Registering one identifier twice kills the app, so each is registered once per run.
    private var registered: Set<String> = []

    func apply(_ work: VideoWork) {
        switch work {
        case .start(let id): start(id)
        case .progress(let id, let fraction): report(id, fraction)
        case .finish(let id, let success): finish(id, success: success)
        }
    }

    private func start(_ id: UUID) {
        guard #available(iOS 26, *) else { return }
        let identifier = Self.identifierPrefix + id.uuidString
        guard !registered.contains(identifier) else { return }
        registered.insert(identifier)
        let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            Task { @MainActor in self?.began(id, task) }
        }
        guard accepted else { return SendLog.note("continued processing not permitted", id) }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Sending video",
                                                       subtitle: "Old Man's Book Club")
        if #available(iOS 27, *) {
            // Apple: not from the main thread; the error comes back on any queue.
            nonisolated(unsafe) let request = request
            DispatchQueue.global(qos: .userInitiated).async {
                BGTaskScheduler.shared.submitTaskRequest(request) { error in
                    guard let error else { return }
                    Task { @MainActor in SendLog.note("continued processing refused", id, "\(error)") }
                }
            }
        } else {
            do { try BGTaskScheduler.shared.submit(request) }
            catch { SendLog.note("continued processing refused", id, "\(error)") }
        }
        SendLog.note("continued processing requested", id)
    }

    private func began(_ id: UUID, _ task: BGTask) {
        guard #available(iOS 26, *), let task = task as? BGContinuedProcessingTask else {
            return task.setTaskCompleted(success: false)
        }
        // Done before iOS got round to starting it.
        if finished.contains(id) { return task.setTaskCompleted(success: true) }
        running[id] = task
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64((progress[id] ?? 0) * 1000)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.ended(id) }
        }
        SendLog.note("continued processing started", id)
    }

    private func report(_ id: UUID, _ fraction: Double) {
        let fraction = min(max(fraction, progress[id] ?? 0), 1)   // never backwards
        progress[id] = fraction
        guard #available(iOS 26, *), let task = running[id] as? BGContinuedProcessingTask else { return }
        task.progress.completedUnitCount = Int64(fraction * 1000)
    }

    private func finish(_ id: UUID, success: Bool) {
        finished.insert(id)
        progress[id] = nil
        guard #available(iOS 26, *), let task = running.removeValue(forKey: id) as? BGContinuedProcessingTask else { return }
        if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
        task.setTaskCompleted(success: success)
        SendLog.note("continued processing done", id, success ? "uploaded" : "stopped")
    }

    private func ended(_ id: UUID) {
        guard #available(iOS 26, *), let task = running.removeValue(forKey: id) as? BGContinuedProcessingTask else { return }
        SendLog.note("continued processing ended by iOS", id)
        task.setTaskCompleted(success: false)
        onEnded?(id)
    }
}
