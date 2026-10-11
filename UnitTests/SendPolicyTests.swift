import XCTest
@testable import OldMansBookClub

/// #204 (U1, U2) — the send path's rules: what a response means, when to try again, and what a
/// pending bubble shows. Pure functions, so every rule is pinned here without a network or an app.
final class SendPolicyTests: XCTestCase {

    // MARK: - Classifying a response (U2)

    func testTwoHundredsAreDelivered() {
        XCTAssertEqual(SendPolicy.verdict(status: 200, error: nil, body: nil, retryAfter: nil), .delivered)
        XCTAssertEqual(SendPolicy.verdict(status: 201, error: nil, body: nil, retryAfter: nil), .delivered)
    }

    func testAnExpiredTokenMeansRefreshAndResend() {
        XCTAssertEqual(SendPolicy.verdict(status: 401, error: nil, body: nil, retryAfter: nil), .refreshAuth)
    }

    func testRateLimitedWaitsForRetryAfter() {
        XCTAssertEqual(SendPolicy.verdict(status: 429, error: nil, body: nil, retryAfter: "17"), .rateLimited(17))
        XCTAssertEqual(SendPolicy.verdict(status: 429, error: nil, body: nil, retryAfter: nil), .rateLimited(nil))
    }

    func testServerTroubleAndTimeoutsAreTransient() {
        for status in [500, 502, 503, 504, 408] {
            guard case .transient = SendPolicy.verdict(status: status, error: nil, body: nil, retryAfter: nil) else {
                return XCTFail("\(status) should be transient")
            }
        }
    }

    func testOtherClientErrorsAreRefusedWithTheServersReason() {
        let body = #"{"error":"Not a member of this club."}"#.data(using: .utf8)
        XCTAssertEqual(SendPolicy.verdict(status: 400, error: nil, body: body, retryAfter: nil),
                       .refused("Not a member of this club."))
        guard case .refused = SendPolicy.verdict(status: 413, error: nil, body: nil, retryAfter: nil) else {
            return XCTFail("413 without a body is still a refusal")
        }
    }

    func testNoNetworkIsOfflineNotAFailedAttempt() {
        for code in [URLError.Code.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff] {
            XCTAssertEqual(SendPolicy.verdict(status: nil, error: URLError(code), body: nil, retryAfter: nil), .offline)
        }
    }

    func testDroppedConnectionsAndTimeoutsAreTransient() {
        for code in [URLError.Code.networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost] {
            guard case .transient = SendPolicy.verdict(status: nil, error: URLError(code), body: nil, retryAfter: nil) else {
                return XCTFail("\(code) should be transient")
            }
        }
    }

    // MARK: - The shared retry clock (U2)

    private let timing = SendTiming()
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testTheScheduleIsAggressiveThenEveryMinuteForever() {
        var clock = RetryClock()
        var gaps: [TimeInterval] = []
        for _ in 0..<9 {
            clock.recordFailure(now: t0, timing: timing, jitter: 0)
            gaps.append(clock.nextAttemptAt!.timeIntervalSince(t0))
        }
        XCTAssertEqual(gaps, [1, 2, 4, 8, 15, 30, 60, 60, 60])   // no cap on attempts
    }

    func testJitterStaysWithinTwentyPercent() {
        for jitter in [-1.0, 1.0, -5.0, 5.0] {
            var clock = RetryClock()
            for _ in 0..<5 { clock.recordFailure(now: t0, timing: timing, jitter: jitter) }   // 5th gap: 15 s
            let gap = clock.nextAttemptAt!.timeIntervalSince(t0)
            XCTAssertGreaterThanOrEqual(gap, 15 * 0.8 - 0.0001)
            XCTAssertLessThanOrEqual(gap, 15 * 1.2 + 0.0001)
        }
    }

    func testGoodNewsResetsTheBackoff() {
        var clock = RetryClock()
        for _ in 0..<6 { clock.recordFailure(now: t0, timing: timing, jitter: 0) }
        XCTAssertFalse(clock.isDue(now: t0.addingTimeInterval(10)))
        clock.reset()
        XCTAssertTrue(clock.isDue(now: t0.addingTimeInterval(10)))
        XCTAssertFalse(clock.isBackingOff)
    }

    func testARateLimitSurvivesGoodNews() {
        // The network coming back says nothing about the server's per-minute limit.
        var clock = RetryClock()
        clock.recordRateLimit(now: t0, retryAfter: 20, timing: timing)
        clock.reset()
        XCTAssertFalse(clock.isDue(now: t0.addingTimeInterval(19)))
        XCTAssertTrue(clock.isDue(now: t0.addingTimeInterval(20)))
    }

    // MARK: - What to send now (U2)

    private func item(_ n: Int, _ status: SendItem.Status = .queued) -> SendItem {
        SendItem(id: UUID(), bookId: UUID(), clubId: UUID(), kind: .text,
                 sentAt: t0.addingTimeInterval(Double(n)), body: "\(n)", status: status)
    }

    func testWithNoRecentFailuresEverythingReadyGoesAtOnce() {
        let items = [item(3), item(1), item(2, .waiting), item(4, .inFlight), item(5, .refused)]
        let ids = SendPolicy.itemsToSubmit(items, clock: RetryClock(), now: t0, isOffline: false)
        // Parallel, not in a line — the order here is only the tap order of what's ready.
        XCTAssertEqual(ids, [items[1].id, items[2].id, items[0].id])
    }

    func testWhileBackingOffOnlyTheOldestGoesAsAProbe() {
        var clock = RetryClock()
        clock.recordFailure(now: t0, timing: timing, jitter: 0)
        let items = (1...10).map { item($0, .waiting) }
        XCTAssertEqual(SendPolicy.itemsToSubmit(items, clock: clock, now: t0, isOffline: false), [],
                       "nothing before the clock is due")
        XCTAssertEqual(SendPolicy.itemsToSubmit(items, clock: clock, now: t0.addingTimeInterval(1), isOffline: false),
                       [items[0].id], "ten waiting photos cost one request per tick, not ten")
    }

    func testNoSecondProbeWhileOneIsInFlight() {
        var clock = RetryClock()
        clock.recordFailure(now: t0, timing: timing, jitter: 0)
        let items = [item(1, .inFlight), item(2, .waiting)]
        XCTAssertEqual(SendPolicy.itemsToSubmit(items, clock: clock, now: t0.addingTimeInterval(5), isOffline: false), [])
    }

    func testTheClockSubmitsNothingWithNoNetwork() {
        // The engine hands these to iOS instead, which waits for the network (SendEngineTests).
        XCTAssertEqual(SendPolicy.itemsToSubmit([item(1)], clock: RetryClock(), now: t0, isOffline: true), [])
    }

    // MARK: - What a pending bubble shows (U1)

    func testSendingThenWaitingAfterAWhileOfFailures() {
        var it = item(1, .waiting)
        it.firstFailureAt = t0
        XCTAssertEqual(it.displayState(now: t0.addingTimeInterval(29), waitingAfter: 30, isOffline: false), .sending)
        XCTAssertEqual(it.displayState(now: t0.addingTimeInterval(30), waitingAfter: 30, isOffline: false), .waiting)
    }

    func testOfflineShowsWaitingStraightAway() {
        var it = item(1, .waiting)
        it.firstFailureAt = t0
        XCTAssertEqual(it.displayState(now: t0, waitingAfter: 30, isOffline: true), .waiting)
    }

    func testHandedToIOSWithNoNetworkShowsWaiting() {
        // iOS has it and is waiting for the network: a spinner would say it's going now.
        XCTAssertEqual(item(1, .inFlight).displayState(now: t0, waitingAfter: 30, isOffline: true), .waiting)
    }

    func testAFreshSendShowsSendingEvenOffline() {
        // Queued, not yet tried: it's on its way as far as the user is concerned.
        XCTAssertEqual(item(1).displayState(now: t0, waitingAfter: 30, isOffline: true), .sending)
    }

    func testARefusalShowsTheReason() {
        var it = item(1, .refused)
        it.refusedReason = "Video is too large (max 100 MB)."
        XCTAssertEqual(it.displayState(now: t0, waitingAfter: 30, isOffline: false), .refused("Video is too large (max 100 MB)."))
    }
}
