import XCTest
@testable import OldMansBookClub

/// #204 design v2 — a picked video is made ready before Send (docs/SEND_REQUIREMENTS.md S2): every
/// refusal shown before anything is sent.
final class VideoPreparationTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/tmp/picked.mov")

    private func prepare(duration: TimeInterval? = 30, result: VideoCompression, sizes: [URL: Int64] = [:]) async -> VideoPreparation.Outcome {
        var progress: [Double] = []
        let outcome = await VideoPreparation.prepare(source, duration: { _ in duration },
                                                     compress: { _, report in report(0.5); return result },
                                                     size: { sizes[$0] ?? 1000 }, progress: { progress.append($0) })
        if case .compressed = result { XCTAssertEqual(progress, [0.5], "progress reaches the composer") }
        return outcome
    }

    func testACompressedCopyIsWhatsSent() async {
        let copy = URL(fileURLWithPath: "/tmp/copy.mp4")
        let outcome = await prepare(result: .compressed(copy))
        XCTAssertEqual(outcome, .ready(copy, compressed: true))
    }

    func testOverFiveMinutesIsRefusedBeforeCompressing() async {
        let outcome = await prepare(duration: 301, result: .unsupported)
        XCTAssertEqual(outcome, .refused("Video is too long (max 5 minutes). Please trim it and try again."))
    }

    func testTooLargeEvenCompressedIsRefusedBeforeSending() async {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        FileManager.default.createFile(atPath: copy.path, contents: Data([1]))
        let outcome = await prepare(result: .compressed(copy), sizes: [copy: SendItem.maxVideoBytes + 1])
        XCTAssertEqual(outcome, .refused("Video is too large (max 100 MB)."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "the oversized copy is cleaned up")
    }

    func testOneThatCantBeCompressedGoesAsItIsIfSmallEnough() async {
        let small = await prepare(result: .unsupported)
        XCTAssertEqual(small, .ready(source, compressed: false))
        let large = await prepare(result: .unsupported, sizes: [source: SendItem.maxVideoBytes + 1])
        XCTAssertEqual(large, .refused("Video is too large (max 100 MB)."))
    }

    func testLeavingTheAppMidwayIsNotARefusal() async {
        let outcome = await prepare(result: .interrupted)
        XCTAssertEqual(outcome, .interrupted)
    }
}
