import XCTest
@testable import OldMansBookClub

/// #213 (docs/SEND_REQUIREMENTS.md "Voice recording") — whatever ends a take sends what was
/// recorded: release, leaving the chat, the background, playback, an interruption (a call, Siri,
/// an alarm). Under half a second is dropped; a take long enough to keep is never lost silently;
/// every way a take ends is logged.
@MainActor
final class RecordingTakeTests: XCTestCase {
    final class FakeRecorder: VoiceRecorder {
        var log: [String] = []
        var noFile = false
        let file = URL(fileURLWithPath: "/tmp/take.m4a")
        func stop() -> (url: URL, duration: Int)? { log.append("stop"); return noFile ? nil : (file, 1) }
    }

    private var recorder: FakeRecorder!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var finished: [(kept: Bool, reason: RecordingEnd)] = []
    private var lost = 0

    override func setUp() async throws {
        recorder = FakeRecorder()
        finished = []
        lost = 0
    }

    private func startTake() -> RecordingTake {
        RecordingTake(
            recorder: recorder, now: { [unowned self] in self.now },
            onLost: { [unowned self] in self.lost += 1 },
            onFinished: { [unowned self] file, reason in self.finished.append((file != nil, reason)) })
    }

    private func wait(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }

    func testC1AnInterruptionSendsWhatWasRecorded() {
        // A call (answered or declined), Siri, an alarm: the take ends and is sent, like any other
        // ending — nothing waits for the interruption to be over.
        let take = startTake()
        wait(8)
        take.finish(.interrupted)

        XCTAssertEqual(finished.map(\.reason), [.interrupted])
        XCTAssertTrue(finished.first?.kept == true)
        XCTAssertEqual(recorder.log, ["stop"])
    }

    func testC4LeavingTheChatSendsTheTake() {
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

    func testAnEndedTakeEndsOnce() {
        // e.g. an interruption ends it, then the finger still holding the mic is lifted.
        let take = startTake()
        wait(2)
        take.finish(.interrupted)
        take.finish(.released)
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(recorder.log, ["stop"])
    }

    func testEveryWayATakeEndsIsLogged() {
        for reason in [RecordingEnd.released, .leftChat, .background, .playback, .interrupted] {
            let take = startTake()
            wait(1)
            take.finish(reason)
            XCTAssertTrue(SendLog.recent(limit: 50).contains("recording ended: \(reason.rawValue)"),
                          "'\(reason.rawValue)' isn't in the send log")
        }
    }

    func testC9ATakeLongEnoughToKeepIsNeverLostSilently() {
        // If the recorder gives back no file, the user is told — it used to vanish (2.2 (7)).
        recorder.noFile = true
        let take = startTake()
        wait(20)
        take.finish(.released)

        XCTAssertEqual(lost, 1)
        XCTAssertEqual(finished.first?.kept, false)
        XCTAssertTrue(SendLog.recent(limit: 5).contains("recording lost"))
    }

    func testATooShortTakeIsDroppedWithoutAnError() {
        recorder.noFile = true
        let take = startTake()
        wait(0.2)
        take.finish(.released)
        XCTAssertEqual(lost, 0, "under half a second is dropped on purpose — not an error")
    }
}
