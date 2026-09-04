import XCTest

/// UI tests with no backend at all: the app is pointed at a stub HTTP server run by this test
/// process (see StubAPIServer).
///
/// These are the flows whose correctness is entirely client-side once the data exists — what the
/// app DRAWS, not what the server computes. Running them without a server buys determinism (the
/// same three books and the same messages every time, never a database that has grown since
/// yesterday) and makes them cheap enough to gate every PR.
///
/// Anything that depends on real server behaviour — blob uploads, SignalR delivery, unread
/// arithmetic — belongs in lane B or in the API integration suite instead, and is NOT here.
final class HermeticUITests: XCTestCase {
    private var server: StubAPIServer!
    private var state: StubState!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        state = StubState()
        state.messages = ["First seeded message", "Second seeded message"]
        server = try StubAPIServer(state: state)
    }

    override func tearDown() {
        server?.stop()
        super.tearDown()
    }

    /// Launches pointed at the stub. `-debugServerBaseURL` lands in UserDefaults, which is exactly
    /// where ServerEnvironment already looks (#120) — so this needs no production code at all.
    ///
    /// `-AppleLanguages`-style resets are not enough on their own: a session persisted in the
    /// Keychain from an earlier run would skip the login screen, so the launch environment also
    /// asks the app to start from a clean slate where it can.
    private func launch() {
        app = XCUIApplication()
        app.launchArguments += [
            "-debugServerBaseURL", server.baseURL,
            "-hasAcceptedEULA", "YES",
        ]
        app.launch()

        let devLogin = app.buttons["Dev Login (Debug)"]
        if devLogin.waitForExistence(timeout: 5) { devLogin.tap() }
    }

    private func openCurrentBook() {
        let discussion = app.staticTexts["Discussion"].firstMatch
        XCTAssertTrue(discussion.waitForExistence(timeout: 15), "Library never rendered from the stub")
        discussion.tap()
        XCTAssertTrue(app.textViews["messageTextField"].waitForExistence(timeout: 10), "Chat never loaded")
    }

    // ---- the library renders from the server's data ------------------------------------------

    func testTheLibraryRendersBothStatusGroups() {
        launch()

        // Two books, one current and one future — the shape the reorder screen and the library
        // sections both depend on. Against a live database this assertion depends on whatever
        // state that database happens to be in.
        XCTAssertTrue(app.staticTexts["Seed: Current Read"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Seed: Future Read"].exists)
    }

    func testTheChatRendersTheMessagesTheServerReturned() {
        launch()
        openCurrentBook()

        XCTAssertTrue(app.staticTexts["First seeded message"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Second seeded message"].exists)
    }

    // ---- send, with the echo reconciled ------------------------------------------------------

    func testASentMessageAppearsOnceNotTwice() {
        launch()
        openCurrentBook()
        let body = "hermetic send \(Int(Date().timeIntervalSince1970))"

        let field = app.textViews["messageTextField"]
        field.tap()
        field.typeText(body)
        app.buttons["sendButton"].tap()

        XCTAssertTrue(app.staticTexts[body].waitForExistence(timeout: 10), "the sent message never appeared")

        // The stub echoes the send back carrying its client_id, which is what the reconciler
        // matches on. Exactly one bubble is the assertion — a second would be #35 returning, and
        // counting is the only way to see it.
        XCTAssertEqual(app.staticTexts.matching(identifier: body).count, 1,
                       "the optimistic bubble and its confirmation both rendered")
    }

    // ---- pure client UI ----------------------------------------------------------------------

    func testTheEmojiPickerRendersItsGridAndSwitchesCategory() {
        // The same assertions as the live-lane version of this test, minus its dependency on a
        // real send: the picker's contents are pure client UI, so proving them needs no server.
        // The live copy exists because the reaction ROUND TRIP does need one.
        launch()
        openCurrentBook()

        let message = app.staticTexts["First seeded message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.press(forDuration: 0.6)

        let plus = app.buttons["addEmojiReactionButton"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "Reaction bar's + button never appeared")
        plus.tap()

        // Deliberately specific emoji, matching the live test's reasoning: 🥰 is in the default
        // smileys grid but is neither a category tab nor a quick reaction, and 🍕 exists only in
        // the food grid. A "did a sheet appear" check would have passed against the broken
        // forced-keyboard picker this replaced.
        XCTAssertTrue(app.buttons["🥰"].waitForExistence(timeout: 10), "Emoji grid never rendered")

        app.buttons["🍔"].firstMatch.tap()
        XCTAssertTrue(app.buttons["🍕"].waitForExistence(timeout: 5),
                      "switching category did not change the grid")

        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(app.buttons["🍕"].waitForExistence(timeout: 3), "the picker never dismissed")
    }
}
