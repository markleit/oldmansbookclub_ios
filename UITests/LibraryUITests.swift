import XCTest

// #138 — series grouping. Follows OldMansBookClubUITests' style (real accessibility hierarchy,
// not screenshot coordinates — see that file's header comment for why). Separate class because
// its setUp needs to land on the Library screen itself, not inside a book's chat.
final class LibraryUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        loginIfNeeded()
    }

    private func loginIfNeeded() {
        // A fresh install (no persisted hasAcceptedEULA) shows Terms of Use first — handle it
        // before looking for Dev Login, or the run just stalls waiting for a button that's
        // behind a full-screen cover.
        let agreeButton = app.buttons["I Agree"]
        if agreeButton.waitForExistence(timeout: 3) {
            agreeButton.tap()
        }

        let devLoginButton = app.buttons["Dev Login (Debug)"]
        if devLoginButton.waitForExistence(timeout: 5) {
            devLoginButton.tap()
        }
        XCTAssertTrue(app.buttons["libraryMenuButton"].waitForExistence(timeout: 10), "Library screen never loaded")
    }

    // Menu items render as regular Buttons (confirmed via an app.debugDescription dump on a
    // failed run) inside a popover CollectionView, so app.buttons[label] is right — but tapping
    // straight into it without a wait races the popover's appear animation. waitForExistence
    // (which polls, unlike a bare query) is what actually fixes it.
    private func tapMenuItem(_ label: String) {
        app.buttons["libraryMenuButton"].tap()
        let item = app.buttons[label]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Menu item '\(label)' never appeared")
        item.tap()
    }

    private func addBook(title: String, series: String? = nil) {
        tapMenuItem("Add Book")

        let titleField = app.textFields["bookTitleField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "Add Book sheet never appeared")
        titleField.tap()
        titleField.typeText(title)

        if let series {
            let seriesField = app.textFields["bookSeriesField"]
            seriesField.tap()
            seriesField.typeText(series)
        }

        app.buttons["saveBookButton"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10), "Book '\(title)' never appeared after saving")
    }

    // Two books sharing a series name should collapse into one grouped header in Future Reads
    // instead of showing as two unrelated rows.
    func testAddBooksToSeries_groupTogetherInFutureReads() {
        let seriesName = "UITest Series \(Int(Date().timeIntervalSince1970))"
        addBook(title: "\(seriesName) — Book One", series: seriesName)
        addBook(title: "\(seriesName) — Book Two", series: seriesName)

        let header = app.staticTexts["\(seriesName) · 2 books"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), "Series header never appeared grouping the two books")
    }

    // A book with no series name should render as a normal standalone row (no group header),
    // confirming the free-text field is genuinely optional.
    func testAddBookWithoutSeries_appearsStandalone() {
        addBook(title: "UITest Standalone \(Int(Date().timeIntervalSince1970))")
    }

    // #144 — the three per-status reorder entries exist and open the right screen. Doesn't drive
    // an actual drag (XCUITest drag gestures on a List are flaky/slow for little signal beyond
    // what this already proves); this is really about the row-tap-into-a-series navigation,
    // which needed a Button + navigationDestination(isPresented:) fix after a List forced into
    // permanent edit mode was found to swallow plain NavigationLink row taps.
    func testReorderMenu_opensCorrectScreenForEachStatus() {
        for (label, title) in [
            ("Manage Currently Reading Order", "Currently Reading Order"),
            ("Manage Future Read Order", "Future Read Order"),
            ("Manage Past Read Order", "Past Read Order"),
        ] {
            tapMenuItem(label)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "\(label) didn't open '\(title)'")
            app.buttons["Cancel"].tap()
        }
    }

    // #144 — tapping a series row inside the Future Read Order reorder screen (which is
    // permanently in edit mode for drag-to-reorder) must still navigate into that series'
    // own reorder screen.
    func testTapSeriesRowInReorderScreen_opensSeriesOrderView() {
        let seriesName = "UITest Series \(Int(Date().timeIntervalSince1970))"
        addBook(title: "\(seriesName) — Book One", series: seriesName)
        addBook(title: "\(seriesName) — Book Two", series: seriesName)

        tapMenuItem("Manage Future Read Order")
        XCTAssertTrue(app.navigationBars["Future Read Order"].waitForExistence(timeout: 5))

        let seriesRow = app.staticTexts[seriesName]
        XCTAssertTrue(seriesRow.waitForExistence(timeout: 5), "Series row never appeared in the reorder list")
        seriesRow.tap()

        XCTAssertTrue(app.navigationBars[seriesName].waitForExistence(timeout: 5), "Tapping the series row never opened its SeriesOrderView")
        XCTAssertTrue(app.staticTexts["\(seriesName) — Book One"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["\(seriesName) — Book Two"].waitForExistence(timeout: 5))
    }
}
