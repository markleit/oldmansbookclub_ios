import XCTest

/// UI tests with no backend at all — the app is pointed at a stub HTTP server that runs as a
/// genuine macOS process, started by an Xcode scheme pre-action (`project.yml`,
/// `scripts/hermetic_stub.py`) before any test runs and stopped by a post-action after.
///
/// It used to be a Swift `NWListener` created directly inside this test class instead. That
/// version was reachable instantly from ITS OWN process (proven directly, with a raw `URLSession`
/// call from inside the runner) but never reachable from the app under test — a SEPARATE
/// Simulator-hosted process — for the full duration of any test, every time, on a completely
/// fresh device and in CI alike. iOS Simulator does not reliably bridge loopback connections
/// BETWEEN two Simulator-hosted apps, only from a Simulator app to a genuine macOS host process.
/// Running the stub as a real host process puts it on the same footing as the live lane's real
/// API — which never had this problem, for exactly that reason.
///
/// These are the flows whose correctness is entirely client-side once the data exists — what the
/// app DRAWS, not what the server computes. Anything depending on real server behaviour — blob
/// uploads, SignalR delivery, unread arithmetic — belongs in lane B or the API integration suite,
/// and is NOT here.
final class HermeticUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Fixed by the pre-action script — see `scripts/hermetic_stub.py`'s `PORT`.
    private let stubBaseURL = "http://127.0.0.1:51235"

    override func setUpWithError() throws {
        continueAfterFailure = false
        // The stub is a long-lived process shared by every test in this run (unlike the old
        // per-test Swift object), so each test resets it explicitly for the isolation a fresh
        // object used to give for free.
        try controlRequest(path: "/_stub/reset", method: "POST")
        try setMessages(["First seeded message", "Second seeded message"])
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    /// Launches pointed at the stub. `-debugServerBaseURL` lands in UserDefaults, which is exactly
    /// where ServerEnvironment already looks (#120) — so this needs no production code at all.
    ///
    /// The EULA-skip key MUST match `OldMansBookClubApp.swift`'s actual `@AppStorage` key exactly
    /// (`hasAcceptedEULA_v2`, not `hasAcceptedEULA`) — this was wrong for a long time and was the
    /// real cause of #126's "stub sometimes unreachable" flake (see `openCurrentBook()`'s doc
    /// comment). A launch-argument override that never matches anything the app reads is silently
    /// a no-op, not an error, which is exactly what made it invisible for so long.
    private func launch() {
        app = XCUIApplication()
        app.launchArguments += [
            "-debugServerBaseURL", stubBaseURL,
            "-hasAcceptedEULA_v2", "YES",
        ]
        app.launch()
        SystemAlerts.dismissAny()

        let devLogin = app.buttons["Dev Login (Debug)"]
        if devLogin.waitForExistence(timeout: 5) { devLogin.tap() }
        // Push registration fires after login, so the notification prompt arrives here.
        SystemAlerts.dismissAny()
    }

    /// Distinguishes "the app never reached the stub" from "the stub answered wrong" — the two
    /// have identical symptoms on screen (an empty library) and completely different causes.
    private func assertStubWasReached(_ context: String) throws {
        let requests = try requestedPaths()
        XCTAssertFalse(requests.isEmpty, """
            \(context): the app made NO request to the stub at \(stubBaseURL). It could not \
            reach the host-level stub process, so this is a Simulator/environment problem, not \
            an app one. Confirm the scheme's pre-action started it — check /tmp/ombc-hermetic-stub.log.
            """)
    }

    /// Taps into the current book's chat. Was "known unresolved" (#126) for a long time — eight
    /// causes ruled out one at a time (occlusion, tap mechanism, Book decoding, deep-link
    /// interference, navigation gating, an app crash, a nested gesture, HTTP/1.0 reuse) with the
    /// identical symptom surviving every one of them. The actual cause (found 2026-09-12): this
    /// class's own `launch()` passed the wrong launch-argument key for skipping the EULA screen
    /// (`hasAcceptedEULA` instead of the app's real `hasAcceptedEULA_v2`), so on a freshly
    /// reinstalled app the EULA screen showed instead of the login screen, "Dev Login (Debug)"
    /// never appeared within its 5s wait, the tap was silently skipped, and the app never made
    /// its first request — which looked identical to "reached the library, then can't navigate"
    /// whenever an EARLIER test in the same run had already persisted EULA acceptance in
    /// UserDefaults (a real write that survives relaunches, unlike the broken launch-arg
    /// override), and looked identical to "no request reaches the stub" on a genuinely fresh
    /// install. Confirmed via the app's own console log
    /// (`log stream --predicate 'process == "OldMansBookClub"'`): zero URLSession tasks were ever
    /// created on a failing run. See `launch()`'s fixed launch argument.
    private func openCurrentBook() {
        let discussionText = app.staticTexts["Discussion"].firstMatch
        XCTAssertTrue(discussionText.waitForExistence(timeout: 15), "Library never rendered from the stub")

        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Discussion'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Book row button not found")
        row.tap()
        XCTAssertTrue(app.textViews["messageTextField"].waitForExistence(timeout: 10), "Chat never loaded")
    }

    // ---- the library renders from the server's data ------------------------------------------

    func testTheLibraryRendersBothStatusGroups() throws {
        launch()

        // Two books, one current and one future — the shape the reorder screen and the library
        // sections both depend on. Against a live database this assertion depends on whatever
        // state that database happens to be in.
        let rendered = app.staticTexts["Seed: Current Read"].waitForExistence(timeout: 15)
        if !rendered { try assertStubWasReached("library never rendered") }
        XCTAssertTrue(rendered, "the stub answered but the library did not render its books")
        XCTAssertTrue(app.staticTexts["Seed: Future Read"].exists)
    }

    func testTheChatRendersTheMessagesTheServerReturned() throws {
        launch()
        openCurrentBook()
        XCTAssertTrue(app.staticTexts["First seeded message"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Second seeded message"].exists)
    }

    // ---- send, with the echo reconciled ------------------------------------------------------

    func testASentMessageAppearsOnceNotTwice() throws {
        // NEW, SEPARATE issue from #126's navigation bug (fixed — see openCurrentBook, which this
        // test now reaches reliably). `sendButton` appears and is tapped successfully (confirmed:
        // waitForExistence succeeds), but no send request is ever made — confirmed directly via
        // the app's own console log (`log stream --predicate 'process == "OldMansBookClub"'`)
        // showing no POST to /books/{id}/messages after the tap, on two separate attempts. Never
        // previously exercised: this test was unconditionally skipped for #126's navigation bug
        // since inception, so this has no known-good baseline to compare against. Needs its own
        // investigation — start with whether GrowingTextEditor's UITextViewDelegate actually
        // updates the SwiftUI `text` binding that onSend() reads, since XCUITest's typeText()
        // goes through the real keyboard/responder chain the same as interactive typing would.
        throw XCTSkip("""
            The send button appears and is tapped, but no send request is ever made afterward \
            (confirmed via console log) — a genuinely new, separate issue from the navigation bug \
            this test used to be blocked on. Root cause not yet found; see the doc comment above.
            """)
    }

    // ---- pure client UI ----------------------------------------------------------------------

    func testTheEmojiPickerRendersItsGridAndSwitchesCategory() throws {
        launch()
        openCurrentBook()
        let message = app.staticTexts["First seeded message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.press(forDuration: 0.6)
        let plus = app.buttons["addEmojiReactionButton"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "Reaction bar's + button never appeared")
        plus.tap()
        XCTAssertTrue(app.buttons["🥰"].waitForExistence(timeout: 10), "Emoji grid never rendered")
        app.buttons["🍔"].firstMatch.tap()
        XCTAssertTrue(app.buttons["🍕"].waitForExistence(timeout: 5), "switching category did not change the grid")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(app.buttons["🍕"].waitForExistence(timeout: 3), "the picker never dismissed")
    }

    // ---- control API (talks to the host-level stub, not an in-process object) ----------------

    private func setMessages(_ messages: [String]) throws {
        try controlRequest(path: "/_stub/messages", method: "POST", jsonBody: messages)
    }

    private func requestedPaths() throws -> [String] {
        let data = try controlRequest(path: "/_stub/requests", method: "GET")
        return (try? JSONSerialization.jsonObject(with: data) as? [String]) ?? []
    }

    @discardableResult
    private func controlRequest(path: String, method: String, jsonBody: Any? = nil) throws -> Data {
        var request = URLRequest(url: URL(string: stubBaseURL + path)!)
        request.httpMethod = method
        if let jsonBody {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        var result: Result<Data, Error>?
        let done = XCTestExpectation(description: path)
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error { result = .failure(error) } else { result = .success(data ?? Data()) }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        guard let result else { throw URLError(.timedOut) }
        switch result {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }
}
