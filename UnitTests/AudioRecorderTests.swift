import XCTest
@testable import OldMansBookClub

/// #213 — AudioRecorder's pause / resume / stop against a stand-in that behaves like AVAudioRecorder
/// on a device: when a call comes in, iOS pauses capture itself, before the app hears of it. The
/// 2.2 (7) device pass found a declined call's take "resumed" on screen and then dropped on release
/// (the send log: paused, resumed, ended recorded=22.8s, nothing queued).
final class AudioRecorderTests: XCTestCase {
    final class Capture: AudioCapture {
        let url: URL
        var isRecording = false
        var deviceCurrentTime: TimeInterval = 100
        var refuses = false
        init(url: URL) { self.url = url }
        func record() -> Bool { begin() }
        func record(atTime: TimeInterval) -> Bool { begin() }
        private func begin() -> Bool {
            guard !refuses else { return false }
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: Data([1])) }
            isRecording = true
            return true
        }
        func pause() { isRecording = false }
        func stop() { isRecording = false }
        /// What iOS does when a call comes in: capture stops, the app isn't asked.
        func interruptedBySystem() { isRecording = false }
    }

    private var capture: Capture!

    private func recorder() throws -> AudioRecorder {
        let recorder = AudioRecorder(makeCapture: { [unowned self] url, _ in
            self.capture = Capture(url: url)
            return self.capture
        })
        try recorder.start(atTime: 100)   // with the start chirp: the chirp owns the session
        return recorder
    }

    func testR1ADeclinedCallResumesCaptureEvenThoughIOSHadAlreadyPausedIt() throws {
        let recorder = try recorder()
        capture.interruptedBySystem()   // the call: iOS pauses capture first
        recorder.pause()                // then the app hears of it

        try recorder.resume(atTime: 101)   // declined: the resume chirp, then capture again

        XCTAssertTrue(capture.isRecording, "capture must really restart, not just say so")
        let take = try XCTUnwrap(recorder.stop(), "the take must be handed over on release")
        XCTAssertEqual(take.url, capture.url)
    }

    func testATakeLiftedDuringTheInterruptionIsStillHandedOver() throws {
        let recorder = try recorder()
        capture.interruptedBySystem()
        recorder.pause()

        XCTAssertNotNil(recorder.stop(), "what was recorded before the call is sent")
    }

    func testAResumeThatCantRestartCaptureSaysSo() throws {
        let recorder = try recorder()
        capture.interruptedBySystem()
        recorder.pause()
        capture.refuses = true

        XCTAssertThrowsError(try recorder.resume(atTime: 101), "so the take sends what it has instead of pretending")
        XCTAssertNotNil(recorder.stop())
    }
}
