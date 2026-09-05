import XCTest
@testable import OldMansBookClub

/// Host parsing for the DEBUG server override. Pure, and it takes hand-typed input from a phone
/// keyboard — a rejection that should have been an acceptance means the developer cannot point the
/// app anywhere, and an acceptance that should have been a rejection used to crash on a
/// force-unwrapped URL.
final class ServerEnvironmentTests: XCTestCase {

    func testABareHostAndPortGetsAScheme() {
        // What you actually type on a phone. Requiring "http://" by hand would make the field
        // unusable for its one purpose.
        XCTAssertEqual(ServerEnvironment.sanitized("192.168.1.5:5235"), "http://192.168.1.5:5235")
    }

    func testAnExplicitSchemeIsKept() {
        XCTAssertEqual(ServerEnvironment.sanitized("https://example.com"), "https://example.com")
        XCTAssertEqual(ServerEnvironment.sanitized("http://Marks-MacBook.local:5235"),
                       "http://Marks-MacBook.local:5235")
    }

    func testTrailingSlashesAreStripped() {
        // Paths are appended to this, so a trailing slash yields "//books" — which some servers
        // accept and some do not, making it a great source of "works on my machine".
        XCTAssertEqual(ServerEnvironment.sanitized("http://example.com///"), "http://example.com")
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(ServerEnvironment.sanitized("  example.com  "), "http://example.com")
    }

    func testUnusableInputIsRejectedRatherThanTurnedIntoABadUrl() {
        // Every one of these would previously have to survive a force-unwrapped URL(string:).
        for raw in ["", "   ", "://", "ftp://example.com", "http://"] {
            XCTAssertNil(ServerEnvironment.sanitized(raw), "should have rejected \(raw.debugDescription)")
        }
    }

    func testOnlyHttpAndHttpsAreAllowed() {
        XCTAssertNil(ServerEnvironment.sanitized("ws://example.com"))
        XCTAssertNil(ServerEnvironment.sanitized("file:///etc/passwd"))
    }

    func testTheProductionUrlIsStillProduction() {
        // A typo here points a release build at nothing. Nothing else in the suite would notice.
        XCTAssertEqual(ServerEnvironment.productionURLString,
                       "https://oldmansbookclub-api.azurewebsites.net")
    }
}
