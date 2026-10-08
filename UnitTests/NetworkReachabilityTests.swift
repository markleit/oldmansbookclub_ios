import XCTest
import Network
@testable import OldMansBookClub

/// #203 — 2.1 (4)'s "network back" trigger never fired on device: airplane mode off reports
/// unsatisfied → requiresConnection → satisfied, and only unsatisfied → satisfied was counted.
final class NetworkReachabilityTests: XCTestCase {
    func testAnyNotSatisfiedToSatisfiedCountsAsBack() {
        XCTAssertTrue(NetworkReachability.cameBack(from: .unsatisfied, to: .satisfied))
        XCTAssertTrue(NetworkReachability.cameBack(from: .requiresConnection, to: .satisfied),
                      "the airplane-mode-off sequence ends requiresConnection → satisfied")
    }

    func testStayingUpOrGoingDownIsNotBack() {
        XCTAssertFalse(NetworkReachability.cameBack(from: .satisfied, to: .satisfied))
        XCTAssertFalse(NetworkReachability.cameBack(from: .satisfied, to: .unsatisfied))
        XCTAssertFalse(NetworkReachability.cameBack(from: .unsatisfied, to: .requiresConnection))
    }
}
