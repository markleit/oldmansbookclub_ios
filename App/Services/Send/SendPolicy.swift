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

    /// Which items to hand to the transport now (#204 decision 2, the shared clock): with no
    /// recent failures, everything that's ready goes at once, in parallel (order comes from each
    /// message's tap time, not from posting order). While backing off, only the OLDEST ready item
    /// goes, as a probe — if the server's down, ten waiting photos cost one request per tick, not
    /// ten — and when the probe lands the clock resets and everything else follows.
    enum TokenChoice: Equatable { case useStored, refresh }

    /// Which token a send hands to iOS. One with plenty of time left is used as is; one about to
    /// expire is refreshed first — but only with a network. Offline a refresh can only wait, and a
    /// hand-over that's waiting when the phone locks never reaches iOS (2.2 (3) device pass: ten
    /// photos sat on the phone until it was opened). So offline the stored token goes, expired or
    /// not: if the server refuses it when iOS sends, that 401 wakes the app to refresh and resend.
    static func tokenChoice(expiresIn: TimeInterval?, minRemaining: TimeInterval, hasNetwork: Bool) -> TokenChoice {
        if let expiresIn, expiresIn > minRemaining { return .useStored }
        return hasNetwork ? .refresh : .useStored
    }

    static func itemsToSubmit(_ items: [SendItem], clock: RetryClock, now: Date, isOffline: Bool) -> [UUID] {
        guard !isOffline, clock.isDue(now: now) else { return [] }
        let ready = items
            .filter { (item: SendItem) -> Bool in item.status == .queued || item.status == .waiting }
            .sorted { (a: SendItem, b: SendItem) -> Bool in
                a.sentAt != b.sentAt ? a.sentAt < b.sentAt : a.id.uuidString < b.id.uuidString
            }
        guard clock.isBackingOff else { return ready.map(\.id) }
        let probeInFlight = items.contains { (item: SendItem) -> Bool in item.status == .inFlight }
        guard !probeInFlight, let probe = ready.first else { return [] }
        return [probe.id]
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
