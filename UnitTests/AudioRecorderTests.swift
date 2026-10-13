import XCTest
@testable import OldMansBookClub

/// #213 — AudioRecorder against a stand-in that behaves like AVAudioRecorder on a device: when a
/// call comes in, iOS stops capture itself, before the app hears of it. The take must still be
/// handed over (2.2 (7): it required capture to be running, so an interrupted take was dropped).
final class AudioRecorderTests: XCTestCase {
    final class Capture: AudioCapture {
        let url: URL
        var isRecording = false
        var deviceCurrentTime: TimeInterval = 100
        init(url: URL) { self.url = url }
        func record() -> Bool { isRecording = true; return true }
        func record(atTime: TimeInterval) -> Bool { isRecording = true; return true }
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

    func testC1AnInterruptedTakeIsHandedOverThoughIOSHadAlreadyStoppedCapture() throws {
        let recorder = try recorder()
        capture.interruptedBySystem()

        let take = try XCTUnwrap(recorder.stop(), "what was recorded before the call is sent")
        XCTAssertEqual(take.url, capture.url)
    }

    func testAReleasedTakeIsHandedOver() throws {
        let recorder = try recorder()
        XCTAssertNotNil(recorder.stop())
        XCTAssertNil(recorder.stop(), "once")
    }
}
