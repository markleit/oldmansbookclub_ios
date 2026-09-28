import XCTest
@testable import OldMansBookClub

/// #178 — the Share extension has no test target and can't be driven from XCUITest without a
/// host app's share sheet, so its decisions live in SharePlan and are pinned here: what gets
/// posted, in what order, and which chat is offered first.
final class SharePlanTests: XCTestCase {
    private let url = URL(string: "https://example.com/review")!

    func testPhotosWithoutCaptionAreOneStepEachInOrder() {
        XCTAssertEqual(SharePlan.steps(for: [.photo, .photo, .photo], caption: "  "),
                       [.photo(0), .photo(1), .photo(2)])
    }

    func testCaptionLeadsThePhotosAsItsOwnMessage() {
        XCTAssertEqual(SharePlan.steps(for: [.photo, .photo], caption: " Chapter 3 map "),
                       [.text("Chapter 3 map"), .photo(0), .photo(1)])
    }

    func testALinkAndItsNoteAreOneMessageNotTwo() {
        XCTAssertEqual(SharePlan.steps(for: [.link(url)], caption: "Great review"),
                       [.text("Great review\nhttps://example.com/review")])
        XCTAssertEqual(SharePlan.steps(for: [.link(url)], caption: ""),
                       [.text("https://example.com/review")])
    }

    func testSharedTextGetsTheNoteAboveIt() {
        XCTAssertEqual(SharePlan.steps(for: [.text("A quote")], caption: "From p. 12"),
                       [.text("From p. 12\n\nA quote")])
    }

    func testSectionsPutTheCurrentReadFirstAndDropEmptyClubs() {
        let a = UUID(), b = UUID(), empty = UUID()
        func book(_ title: String, _ status: String, _ club: UUID) -> ShareBook {
            ShareBook(id: UUID(), clubId: club, title: title, author: "x", status: status)
        }
        let sections = SharePlan.sections(
            books: [book("Zed", "past", a), book("Alpha", "future", a), book("Now", "current", a),
                    book("Other", "current", b)],
            clubs: [ShareClub(id: a, name: "Club A"), ShareClub(id: empty, name: "Empty"),
                    ShareClub(id: b, name: "Club B")])

        XCTAssertEqual(sections.map(\.name), ["Club A", "Club B"])
        XCTAssertEqual(sections[0].books.map(\.title), ["Now", "Alpha", "Zed"])
    }

    func testProgressCountsPhotosNotMessages() {
        // Two photos + a caption is three messages; the label must still say "of 2".
        let steps = SharePlan.steps(for: [.photo, .photo], caption: "Look")
        XCTAssertEqual(steps.map { SharePlan.progressLabel(for: $0, photoCount: 2) },
                       ["Sending your message…", "Sending photo 1 of 2…", "Sending photo 2 of 2…"])
    }

    func testSinglePhotoAndTextOnlyLabels() {
        XCTAssertEqual(SharePlan.progressLabel(for: .photo(0), photoCount: 1), "Sending photo…")
        XCTAssertEqual(SharePlan.progressLabel(for: .text("x"), photoCount: 0), "Sending…")
    }
}
