import Foundation

/// Why a voice take ended — written to the send log (#213), so a "my message got cut off" report
/// says what cut it.
enum RecordingEnd: String {
    case released = "released"                          // the user stopped it
    case leftChat = "left the chat"
    case background = "app left the foreground"
    case playback = "playback started"
    case interrupted = "interrupted for more than 15 s" // a call answered, or anything long
    case resumeFailed = "couldn't resume after an interruption"
}

/// What a take needs from the microphone side. `AudioRecorder` in the app; a stand-in in tests.
protocol VoiceRecorder: AnyObject {
    func pause()
    /// `atTime`: an audio-device-clock time to resume capture at — just after the resume chirp.
    func resume(atTime: TimeInterval?) throws
    /// Ends capture (paused or not) and hands over the file.
    func stop() -> (url: URL, duration: Int)?
}

/// #213 (#204 PR 8) — one voice take, from the moment capture starts to the moment it's sent or
/// dropped. A declined call, Siri or an alarm pauses it: over within 15 s, it resumes into the same
/// message (a chirp and "Recording resumed" — the caller's part); longer, or a call answered, and
/// what was recorded is sent. In hold-to-talk, lifting the finger during the pause sends it, so a
/// take only resumes if it's still held. Under half a second of audio is dropped.
@MainActor
final class RecordingTake {
    static let resumeWindow: TimeInterval = 15
    static let minimumDuration: TimeInterval = 0.5

    private let recorder: VoiceRecorder
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    private let onFinished: (_ take: (url: URL, duration: Int)?, _ reason: RecordingEnd) -> Void
    private let onLost: () -> Void
    private let startedAt: Date
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var cancelTimeout: (() -> Void)?
    private(set) var isFinished = false

    var isPaused: Bool { pausedAt != nil }

    /// Over within the window and not ended meanwhile: worth the resume chirp.
    var canResume: Bool {
        guard !isFinished, let pausedAt else { return false }
        return now().timeIntervalSince(pausedAt) <= Self.resumeWindow
    }

    /// Seconds of audio so far — paused time doesn't count.
    var recordedSeconds: TimeInterval {
        now().timeIntervalSince(startedAt) - pausedTotal - (pausedAt.map { now().timeIntervalSince($0) } ?? 0)
    }

    /// `onFinished`: the take (nil when dropped as too short, or lost) and why it ended. `onLost`: a
    /// take long enough to keep, but the recorder gave back no file — never silently (#213).
    init(recorder: VoiceRecorder, now: @escaping () -> Date,
         schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void,
         onLost: @escaping () -> Void = {},
         onFinished: @escaping (_ take: (url: URL, duration: Int)?, _ reason: RecordingEnd) -> Void) {
        self.recorder = recorder
        self.now = now
        self.schedule = schedule
        self.onLost = onLost
        self.onFinished = onFinished
        self.startedAt = now()
    }

    /// A call, Siri or an alarm took the microphone.
    func interruptionBegan() {
        guard !isFinished, pausedAt == nil else { return }
        recorder.pause()
        pausedAt = now()
        SendLog.note("recording paused: interruption")
        cancelTimeout = schedule(Self.resumeWindow) { [weak self] in self?.finish(.interrupted) }
    }

    /// The interruption is over and `canResume` was true: capture continues into the same file.
    func resume(atTime: TimeInterval?) {
        guard canResume, let since = pausedAt else { return }
        cancelTimeout?()
        cancelTimeout = nil
        do {
            try recorder.resume(atTime: atTime)
        } catch {
            finish(.resumeFailed)
            return
        }
        pausedTotal += now().timeIntervalSince(since)
        pausedAt = nil
        SendLog.note("recording resumed")
    }

    /// Ends the take: handed over if there's at least half a second of audio, dropped otherwise.
    @discardableResult
    func finish(_ reason: RecordingEnd) -> Bool {
        guard !isFinished else { return false }
        let recorded = recordedSeconds
        isFinished = true
        cancelTimeout?()
        cancelTimeout = nil
        let take = recorder.stop()
        SendLog.note("recording ended: \(reason.rawValue)", nil, String(format: "recorded=%.1fs", recorded))
        guard recorded >= Self.minimumDuration else {
            onFinished(nil, reason)
            return false
        }
        guard let take else {
            SendLog.note("recording lost: the recorder gave back no file")
            onLost()
            onFinished(nil, reason)
            return false
        }
        onFinished(take, reason)
        return true
    }
}
