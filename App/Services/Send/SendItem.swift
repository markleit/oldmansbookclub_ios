import Foundation

// #204 — one message the user has sent that the server hasn't confirmed yet.
//
// The whole of "fire and forget" rests on this being on disk before anything goes over the
// network: from the moment a bubble appears, the message survives a crash, a force-quit, a reboot,
// and leaving the chat. The SendEngine owns every item; the chat screen only draws them.
struct SendItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case text, voice, photo, video, forward
    }

    enum Status: String, Codable {
        /// Ready to go (never tried, or due for another try).
        case queued
        /// A request for it is with the server or with iOS right now.
        case inFlight
        /// Tried and failed for a reason that can pass (no network, server trouble, rate limit).
        /// Retried automatically on the shared schedule — never shown red.
        case waiting
        /// The server refused it for good (not a member, too large, …). Shown red with the reason;
        /// only the user can resolve it (Copy, Delete).
        case refused
    }

    /// The client id the server dedups by — and the pending bubble's id.
    let id: UUID
    let bookId: UUID
    let clubId: UUID
    let kind: Kind
    /// When the user tapped Send. Sent to the server as `sent_at`, which orders the chat (#204,
    /// decision 1b), so every send is stamped strictly later than the one before (Outbox.nextSentAt).
    let sentAt: Date

    var body: String?
    /// The media file, in the Outbox's files directory (voice / photo / video).
    var fileName: String?
    var contentType: String?
    var durationSeconds: Int?
    var parentMessageId: UUID?
    var parentSenderName: String?
    var parentPreview: String?
    /// A forward of this saved message (PR 9).
    var forwardMessageId: UUID?
    /// The blob is already uploaded (video's upload-link path, or a migrated 2.1 item): only the
    /// JSON post with this `media_url` remains.
    var mediaUrl: String?
    /// A video still to be compressed (PR 5): queued at once, so the composer is free, and
    /// compressed before its upload. Optional so items saved before it existed still load.
    var compressPending: Bool?
    /// The video as picked, kept until it's sent; `fileName` is then the compressed copy.
    var originalFileName: String?
    /// From the share sheet (PR 10), whose upload iOS is carrying in this background session. The app
    /// can't ask that session what it holds until iOS wakes it for it, so the item waits rather
    /// than being started again.
    var shareSession: String?
    /// A reserved video whose upload has landed (#204 design v2): the server creates the message
    /// itself, so it's no longer unsent — the app only confirms it (its post returns the message).
    var serverCreates: Bool?
    /// The upload slot a video goes to (VideoSlots), kept so a retry reuses its blob.
    var slot: VideoSlot?
    /// Storage refused its slot upload: from then on it's reserved, which can answer that it's
    /// already sent — another slot would only upload it all again.
    var reserveOnly: Bool?

    var status: Status = .queued
    var attempts: Int = 0
    /// When it started failing. Drives "sending" → "waiting" after a short while (SendTiming).
    var firstFailureAt: Date?
    var lastError: String?
    var refusedReason: String?
}

/// What a pending bubble shows (#204, decision 2/3).
enum SendDisplayState: Equatable {
    /// Spinner: going now, or failing only briefly.
    case sending
    /// Quiet clock: offline, or still retrying after a while. Menu: Send now, Delete.
    case waiting
    /// Red, with the server's reason. Menu: Copy (text), Delete.
    case refused(String)
}

extension SendItem {
    /// The server's cap on a video (MessageSendService.MaxVideoBytes).
    static let maxVideoBytes: Int64 = 100 * 1024 * 1024

    func displayState(now: Date, waitingAfter: TimeInterval, isOffline: Bool) -> SendDisplayState {
        if status == .refused { return .refused(refusedReason ?? "Couldn't send this message.") }
        // No network: whether it's waiting on the clock or handed to iOS (which waits for the
        // network), the honest state is "waiting", not a spinner.
        if isOffline && (status == .waiting || status == .inFlight) { return .waiting }
        if let since = firstFailureAt, now.timeIntervalSince(since) >= waitingAfter { return .waiting }
        return .sending
    }

    /// The message type the server stores (a forward takes the original's, decided server-side).
    var messageType: MessageType {
        switch kind {
        case .text, .forward: return .text
        case .voice: return .voice
        case .photo: return .photo
        case .video: return .video
        }
    }
}

/// Timings the send path runs on, with DEBUG-only overrides (#204 T2) so UI and device tests can
/// run the real schedule in seconds instead of minutes. RELEASE always uses the defaults.
struct SendTiming: Equatable {
    /// Retry gaps after 1, 2, 3… consecutive failures; the last repeats forever. No cap.
    var backoff: [TimeInterval] = [1, 2, 4, 8, 15, 30, 60]
    /// ± this fraction of jitter on every gap, so phones don't retry in lockstep.
    var jitter: Double = 0.2
    /// Failing this long turns the spinner into the quiet "waiting" clock.
    var waitingAfter: TimeInterval = 30
    /// Voice/photo also go directly (not only via iOS's background transfer) if the background
    /// copy hasn't landed after this long while the app is open.
    var directNudge: TimeInterval = 3
    /// Even with no network signal, check this often in case the "network back" event is missed.
    var offlineCheck: TimeInterval = 60
    /// The force-quit reminder (PR 7) comes this long after the oldest unsent message.
    var reminderAfter: TimeInterval = 600

    static var current: SendTiming {
        var timing = SendTiming()
        #if DEBUG
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "sendTimingScale") != nil {
            let scale = defaults.double(forKey: "sendTimingScale")
            timing.backoff = timing.backoff.map { $0 * scale }
            timing.offlineCheck *= scale
        }
        if defaults.object(forKey: "sendWaitingAfter") != nil { timing.waitingAfter = defaults.double(forKey: "sendWaitingAfter") }
        if defaults.object(forKey: "sendDirectNudge") != nil { timing.directNudge = defaults.double(forKey: "sendDirectNudge") }
        if defaults.object(forKey: "sendReminderAfter") != nil { timing.reminderAfter = defaults.double(forKey: "sendReminderAfter") }
        #endif
        return timing
    }
}
