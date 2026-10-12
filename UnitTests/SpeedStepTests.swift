import XCTest
@testable import OldMansBookClub

/// #190 — the −/+ speed buttons step 0.05× (2.2; was 0.25×) and snap a free slider value to the
/// 0.05 grid.
final class SpeedStepTests: XCTestCase {
    func testStepsAFiftiethOfAMultiplierAtATime() {
        XCTAssertEqual(SpeedStep.up(1.0), 1.05)
        XCTAssertEqual(SpeedStep.up(2.25), 2.3)
        XCTAssertEqual(SpeedStep.down(2.5), 2.45)
        XCTAssertEqual(SpeedStep.down(1.05), 1.0)
    }

    func testEveryTapLandsExactlyOnTheValueItShows() {
        // Repeated taps must not drift (1.1500000000000001 shows as "1.15×" but compares unequal
        // to the slider's 1.15, which would disable the wrong button at the ends).
        var value = 1.0
        for n in 21...80 {
            value = SpeedStep.up(value)
            XCTAssertEqual(value, Double(n) / 20)
        }
        XCTAssertEqual(value, 4.0)
        for n in (20...79).reversed() {
            value = SpeedStep.down(value)
            XCTAssertEqual(value, Double(n) / 20)
        }
        XCTAssertEqual(value, 1.0)
    }

    func testAValueBetweenStepsSnapsToTheNextStepInThatDirection() {
        XCTAssertEqual(SpeedStep.up(2.32), 2.35)
        XCTAssertEqual(SpeedStep.down(2.32), 2.3)
        XCTAssertEqual(SpeedStep.up(1.01), 1.05)
        XCTAssertEqual(SpeedStep.down(3.99), 3.95)
    }

    func testClampsAtTheEnds() {
        XCTAssertEqual(SpeedStep.up(4.0), 4.0)
        XCTAssertEqual(SpeedStep.up(3.97), 4.0)
        XCTAssertEqual(SpeedStep.down(1.0), 1.0)
        XCTAssertEqual(SpeedStep.down(1.02), 1.0)
    }

    func testFloatNoiseFromTheSliderDoesNotSkipAStep() {
        // The slider rounds to 0.05 via Double math; 2.5000000001 / 2.4999999999 must act like 2.5.
        XCTAssertEqual(SpeedStep.up(2.5000000001), 2.55)
        XCTAssertEqual(SpeedStep.down(2.4999999999), 2.45)
    }
}
