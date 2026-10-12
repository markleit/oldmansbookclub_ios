import Foundation

// #204 — the decisions of the send path, as plain functions so every rule is unit-tested without a
// network, a clock or an app (SendPolicyTests). The SendEngine applies them; it doesn't make them.

/// What a response (or a transport error) means for the message.
enum SendVerdict: Equatable {
    /// 2xx — the server has it.
    case delivered
    /// 401 — the access token expired: refresh it and send again at once.
    case refreshAuth
    /// 429 — over the per-minute limit: wait this long (Retry-After), then continue.
    case rateLimited(TimeInterval?)
    /// No network path at all — wait for one; don't count it as a failed attempt.
    case offline
    /// Could pass (5xx, timeout, connection dropped): retry on the schedule.
    case transient(String)
    /// The server refused it for good: stop and show the reason.
    case refused(String)
}

enum SendPolicy {

    // MARK: Classifying a response

    static func verdict(status: Int?, error: Error?, body: Data?, retryAfter: String?) -> SendVerdict {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            default:
                return .transient("URLError \(urlError.code.rawValue)")
            }
        }
        if let error { return .transient(String(describing: error)) }
        guard let status else { return .transient("no response") }
        switch status {
        case 200..<300:
            return .delivered
        case 401:
            return .refreshAuth
        case 408:
            return .transient("HTTP 408")
        case 429:
            return .rateLimited(retryAfter.flatMap(TimeInterval.init))
        case 400..<500:
            return .refused(serverReason(body) ?? (status == 403
                ? "You don't have access to this chat."
                : "The server couldn't accept this message (\(status))."))
        default:
            return .transient("HTTP \(status)")
        }
    }

    /// The `{error}` text the API puts on a refusal — shown to the user verbatim.
    static func serverReason(_ body: Data?) -> String? {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let reason = json["error"] as? String, !reason.isEmpty else { return nil }
        return reason
    }

    // MARK: When to send

    /// A book's unsent messages, for its Library row (PR 7): "N unsent", red if any was refused.
    struct UnsentSummary: Equatable {
        var count = 0
        var anyRefused = false
    }

    static func unsent(in items: [SendItem], bookId: UUID) -> UnsentSummary {
        // A video whose upload has landed is the server's to create (design v2): not unsent.
        let mine = items.filter { $0.bookId == bookId && $0.serverCreates != true }
        return UnsentSummary(count: mine.count, anyRefused: mine.contains { $0.status == .refused })
    }

    enum TokenChoice: Equatable { case useStored, refresh }

    /// Whether a send's token is renewed first (APIClient.sendToken). One with plenty of time left —
    /// the week-long send token, nearly always — is used as is; one near its end is renewed first,
    /// but only with a network: offline a renewal can only fail, so the one we have goes.
    static func tokenChoice(expiresIn: TimeInterval?, minRemaining: TimeInterval, hasNetwork: Bool) -> TokenChoice {
        if let expiresIn, expiresIn > minRemaining { return .useStored }
        return hasNetwork ? .refresh : .useStored
    }

    /// Which items get a carrier now (#204 design v2). Everything `.queued` — a new message, or one
    /// whose next step is ready — at once, whatever the network or the clock: iOS holds the carrier
    /// until both allow, with the app asleep. A video whose upload has landed is the server's to
    /// create; its post only confirms it, so that waits for the app to be open. Anything `.waiting`
    /// couldn't have a carrier (no token yet, a video offline): it's tried again when the clock is
    /// due — while backing off only the oldest, as a probe.
    static func itemsToSubmit(_ items: [SendItem], clock: RetryClock, now: Date, isAppActive: Bool) -> [UUID] {
        let ordered = inTapOrder(items)
        let queued = ordered.filter { $0.status == .queued && (isAppActive || $0.serverCreates != true) }
        guard clock.isDue(now: now) else { return queued.map(\.id) }
        let waiting = ordered.filter { $0.status == .waiting }
        return (queued + (clock.isBackingOff ? Array(waiting.prefix(1)) : waiting)).map(\.id)
    }

    /// The fast path's retries (the app is open): what iOS holds but is failing also goes directly
    /// when the clock is due — while backing off only the oldest, as a probe; when it lands the clock
    /// resets and the rest follow.
    static func directRetries(_ items: [SendItem], clock: RetryClock) -> [UUID] {
        let failing = inTapOrder(items).filter { $0.status == .inFlight && $0.firstFailureAt != nil }
        return (clock.isBackingOff ? Array(failing.prefix(1)) : failing).map(\.id)
    }

    private static func inTapOrder(_ items: [SendItem]) -> [SendItem] {
        items.sorted { (a: SendItem, b: SendItem) -> Bool in
            a.sentAt != b.sentAt ? a.sentAt < b.sentAt : a.id.uuidString < b.id.uuidString
        }
    }
}

/// The ONE retry clock every queued message shares (#204 decision 2): aggressive at first
/// (1, 2, 4, 8, 15, 30 s), then every 60 s for as long as it takes, each gap ± jitter.
struct RetryClock: Equatable {
    private(set) var failures = 0
    private(set) var nextAttemptAt: Date?
    /// A 429's Retry-After. Survives `reset()`: good news about the network says nothing about
    /// the server's rate limit.
    private(set) var notBefore: Date?

    var isBackingOff: Bool { failures > 0 }

    func isDue(now: Date) -> Bool {
        if let notBefore, now < notBefore { return false }
        if let nextAttemptAt, now < nextAttemptAt { return false }
        return true
    }

    /// The earliest moment anything may be sent, if it's in the future.
    func nextDue(after now: Date) -> Date? {
        [nextAttemptAt, notBefore].compactMap { $0 }.filter { $0 > now }.max()
    }

    /// `jitter` in [-1, 1], scaled by `timing.jitter` — injected so tests are deterministic.
    mutating func recordFailure(now: Date, timing: SendTiming, jitter: Double) {
        failures += 1
        let gap = timing.backoff[min(failures - 1, timing.backoff.count - 1)]
        nextAttemptAt = now.addingTimeInterval(gap * (1 + timing.jitter * max(-1, min(1, jitter))))
    }

    mutating func recordRateLimit(now: Date, retryAfter: TimeInterval?, timing: SendTiming) {
        let wait = retryAfter ?? timing.backoff.last ?? 60
        notBefore = now.addingTimeInterval(max(wait, 1))
    }

    /// Something worked, or the world changed for the better (network back, app opened, Send
    /// now): try again right away.
    mutating func reset() {
        failures = 0
        nextAttemptAt = nil
    }

    mutating func clearRateLimit(now: Date) {
        if let notBefore, now >= notBefore { self.notBefore = nil }
    }
}
