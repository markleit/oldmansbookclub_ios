import Foundation

/// Why a voice take ended — written to the send log (#213), so a "my message got cut off" report
/// says what cut it.
enum RecordingEnd: String {
    case released = "released"                          // the user stopped it
    case leftChat = "left the chat"
    case background = "app left the foreground"
    case playback = "playback started"
    case interrupted = "interrupted (a call, Siri or an alarm)"
}

/// What a take needs from the microphone side. `AudioRecorder` in the app; a stand-in in tests.
protocol VoiceRecorder: AnyObject {
    /// Ends capture and hands over the file — whatever iOS did to capture meanwhile.
    func stop() -> (url: URL, duration: Int)?
}

/// #213 — one voice take, from the moment capture starts to the moment it's sent or dropped.
/// Whatever ends it sends what was recorded: releasing the mic, leaving the chat, the app leaving
/// the foreground, playback starting — and an interruption (a call, Siri, an alarm). To carry on,
/// the user starts a new recording. (Resuming into the same message after a short interruption was
/// tried in 2.2 (7)–(8): on a device the recorder captured nothing after it. Mark chose this
/// simpler rule instead, 2026-10-13.) Under half a second of audio is dropped; a take long enough
/// to keep is never lost silently.
@MainActor
final class RecordingTake {
    static let minimumDuration: TimeInterval = 0.5

    private let recorder: VoiceRecorder
    private let now: () -> Date
    private let onFinished: (_ take: (url: URL, duration: Int)?, _ reason: RecordingEnd) -> Void
    private let onLost: () -> Void
    private let startedAt: Date
    private(set) var isFinished = false

    var recordedSeconds: TimeInterval { now().timeIntervalSince(startedAt) }

    /// `onFinished`: the take (nil when dropped as too short, or lost) and why it ended. `onLost`: a
    /// take long enough to keep, but the recorder gave back no file — never silently.
    init(recorder: VoiceRecorder, now: @escaping () -> Date,
         onLost: @escaping () -> Void = {},
         onFinished: @escaping (_ take: (url: URL, duration: Int)?, _ reason: RecordingEnd) -> Void) {
        self.recorder = recorder
        self.now = now
        self.onLost = onLost
        self.onFinished = onFinished
        self.startedAt = now()
    }

    /// Ends the take: handed over if there's at least half a second of audio, dropped otherwise.
    @discardableResult
    func finish(_ reason: RecordingEnd) -> Bool {
        guard !isFinished else { return false }
        let recorded = recordedSeconds
        isFinished = true
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
