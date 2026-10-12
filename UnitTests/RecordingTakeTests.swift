import XCTest
@testable import OldMansBookClub

/// #213 (#204 PR 8, U13; docs/SEND_REQUIREMENTS.md "Voice recording") — a call, Siri or an alarm
/// pauses a take; over within 15 s it resumes into the same message, otherwise what was recorded
/// is sent; every way a take ends is logged.
@MainActor
final class RecordingTakeTests: XCTestCase {
    final class FakeRecorder: VoiceRecorder {
        var log: [String] = []
        var resumeFails = false
        let file = URL(fileURLWithPath: "/tmp/take.m4a")
        func pause() { log.append("pause") }
        func resume(atTime: TimeInterval?) throws {
            if resumeFails { throw URLError(.cannotOpenFile) }
            log.append("resume")
        }
        func stop() -> (url: URL, duration: Int)? { log.append("stop"); return (file, 1) }
    }

    private var recorder: FakeRecorder!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var timers: [(due: Date, action: @MainActor () -> Void, cancelled: Bool)] = []
    private var finished: [(kept: Bool, reason: RecordingEnd)] = []

    override func setUp() async throws {
        recorder = FakeRecorder()
        timers = []
        finished = []
    }

    private func startTake() -> RecordingTake {
        RecordingTake(
            recorder: recorder, now: { [unowned self] in self.now },
            schedule: { [unowned self] delay, action in
                let index = self.timers.count
                self.timers.append((self.now.addingTimeInterval(delay), action, false))
                return { [weak self] in self?.timers[index].cancelled = true }
            },
            onFinished: { [unowned self] file, reason in self.finished.append((file != nil, reason)) })
    }

    /// Moves the clock on, firing any timer that falls due.
    private func wait(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        for index in timers.indices where !timers[index].cancelled && timers[index].due <= now {
            timers[index].cancelled = true
            timers[index].action()
        }
    }

    func testR1ADeclinedCallWithin15sResumesIntoTheSameMessage() {
        let take = startTake()
        wait(4)
        take.interruptionBegan()
        wait(6)                       // declined: over in 6 s
        XCTAssertTrue(take.canResume)
        take.resume(atTime: nil)
        wait(5)
        take.finish(.released)

        XCTAssertEqual(recorder.log, ["pause", "resume", "stop"], "one file: paused, resumed, stopped")
        XCTAssertEqual(finished.map(\.reason), [.released], "one message, both parts")
        XCTAssertEqual(take.recordedSeconds, 9, accuracy: 0.001, "the pause isn't counted")
    }

    func testR2R3AnAnsweredCallOrOneOver15sSendsWhatWasRecorded() {
        let take = startTake()
        wait(4)
        take.interruptionBegan()
        wait(15)                      // still on the call

        XCTAssertEqual(finished.map(\.reason), [.interrupted])
        XCTAssertTrue(finished.first?.kept == true, "the 4 s said before the call are sent")
        XCTAssertFalse(take.canResume, "and it doesn't come back after the call")
        take.resume(atTime: nil)
        XCTAssertFalse(recorder.log.contains("resume"))
    }

    func testR4HoldToTalkLiftedDuringTheInterruptionSendsWithoutResuming() {
        // Lifting the finger stops the take (the chat calls finish); it can't resume after that.
        let take = startTake()
        wait(3)
        take.interruptionBegan()
        wait(2)
        take.finish(.released)
        wait(2)

        XCTAssertFalse(take.canResume)
        XCTAssertEqual(recorder.log, ["pause", "stop"])
        XCTAssertEqual(finished.map(\.reason), [.released])
    }

    func testC8LeavingTheChatSendsTheTake() {
        let take = startTake()
        wait(5)
        take.finish(.leftChat)
        XCTAssertTrue(finished.first?.kept == true)
        XCTAssertEqual(finished.first?.reason, .leftChat)
    }

    func testUnderHalfASecondIsDropped() {
        let take = startTake()
        wait(0.3)
        take.finish(.released)
        XCTAssertTrue(finished.first?.kept == false, "an accidental tap isn't sent")
    }

    func testWhenItCantResumeWhatWasRecordedIsSent() {
        recorder.resumeFails = true
        let take = startTake()
        wait(4)
        take.interruptionBegan()
        wait(3)
        take.resume(atTime: nil)
        XCTAssertEqual(finished.map(\.reason), [.resumeFailed])
        XCTAssertTrue(finished.first?.kept == true)
    }

    func testAnEndedTakeEndsOnce() {
        let take = startTake()
        wait(2)
        take.finish(.released)
        take.finish(.leftChat)       // the chat closing right after
        XCTAssertEqual(finished.count, 1)
    }

    func testEveryWayATakeEndsIsLogged() {
        for reason in [RecordingEnd.released, .leftChat, .background, .playback, .interrupted, .resumeFailed] {
            let take = startTake()
            wait(1)
            take.finish(reason)
            XCTAssertTrue(SendLog.recent(limit: 50).contains("recording ended: \(reason.rawValue)"),
                          "'\(reason.rawValue)' isn't in the send log")
        }
    }
}
