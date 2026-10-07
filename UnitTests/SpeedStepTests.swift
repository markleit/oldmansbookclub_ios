import XCTest
@testable import OldMansBookClub

/// #190 — the −/+ speed buttons step 0.25× and snap a free slider value to the quarter grid.
final class SpeedStepTests: XCTestCase {
    func testStepsAQuarterFromAQuarter() {
        XCTAssertEqual(SpeedStep.up(1.0), 1.25)
        XCTAssertEqual(SpeedStep.up(2.25), 2.5)
        XCTAssertEqual(SpeedStep.down(2.5), 2.25)
        XCTAssertEqual(SpeedStep.down(1.25), 1.0)
    }

    func testASliderValueBetweenQuartersSnapsToTheNextQuarterInThatDirection() {
        XCTAssertEqual(SpeedStep.up(2.3), 2.5)
        XCTAssertEqual(SpeedStep.down(2.3), 2.25)
        XCTAssertEqual(SpeedStep.up(1.05), 1.25)
        XCTAssertEqual(SpeedStep.down(3.95), 3.75)
    }

    func testClampsAtTheEnds() {
        XCTAssertEqual(SpeedStep.up(4.0), 4.0)
        XCTAssertEqual(SpeedStep.up(3.9), 4.0)
        XCTAssertEqual(SpeedStep.down(1.0), 1.0)
        XCTAssertEqual(SpeedStep.down(1.1), 1.0)
    }

    func testFloatNoiseFromTheSliderDoesNotSkipAQuarter() {
        // The slider rounds to 0.05 via Double math; 2.5000000001 / 2.4999999 must act like 2.5.
        XCTAssertEqual(SpeedStep.up(2.5000000001), 2.75)
        XCTAssertEqual(SpeedStep.down(2.4999999999), 2.25)
    }
}
