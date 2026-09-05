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
    private func launch() {
        app = XCUIApplication()
        app.launchArguments += [
            "-debugServerBaseURL", stubBaseURL,
            "-hasAcceptedEULA", "YES",
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

    /// KNOWN, UNRESOLVED (#126): tapping a book row to enter its chat does not navigate at all
    /// against the host-level stub — the nav bar stays on the library, every time, deterministically.
    /// Every test that calls this is skipped until it is understood; see the skip messages below
    /// for the full list of what has already been ruled out, so nobody re-derives it from scratch.
    private func openCurrentBook() {
        let discussionText = app.staticTexts["Discussion"].firstMatch
        XCTAssertTrue(discussionText.waitForExistence(timeout: 15), "Library never rendered from the stub")

        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Discussion'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Book row button not found")
        row.tap()
        XCTAssertTrue(app.textViews["messageTextField"].waitForExistence(timeout: 10), "Chat never loaded")
    }

    /// Shared skip reason for every test below that needs to get past `openCurrentBook()`.
    /// Ruled out directly, one at a time, all with the identical symptom persisting: element
    /// occlusion (a coordinate tap bypassing XCUITest's own hittable gate still doesn't navigate),
    /// tap mechanism (`.tap()`, coordinate tap, `.doubleTap()` — no difference), `Book`
    /// decoding/hashing (both books render every field correctly), deep-link interference
    /// (`navigateToPendingBook()` is never even called — instrumented directly), conditional
    /// navigation gating (the view code is a plain `NavigationLink(value:)`, nothing wraps it), an
    /// app crash (checked the system console log — one PID throughout, zero fatal errors), a
    /// nested gesture stealing the tap (`CurrentBookCard`/`CachedBookCover` contain no
    /// buttons or gestures), and an HTTP/1.0 connection-reuse hang in the stub (set
    /// `protocol_version = "HTTP/1.1"` in hermetic_stub.py — no change). The live lane's identical
    /// interaction, against the real API, has never once failed this way — so it is specific to
    /// something about this stub, not to XCUITest, the Simulator, or the app in general.
    private static let navigationSkipReason = """
        #126: entering a book's chat does not navigate against the host-level hermetic stub —         the nav bar never leaves the library, deterministically, on every attempt. Eight distinct         causes ruled out by direct testing (see openCurrentBook's doc comment); root cause not yet         found. The identical interaction is covered by the live lane         (OldMansBookClubUITests/LibraryUITests), which passes reliably, so this is a LANE gap, not         a coverage gap — but it does mean HermeticUITests currently proves only that the library         screen renders from the stub, not anything past it.
        """

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
        throw XCTSkip(Self.navigationSkipReason)
        // Re-enable once openCurrentBook() navigates again:
        //   launch()
        //   openCurrentBook()
        //   XCTAssertTrue(app.staticTexts["First seeded message"].waitForExistence(timeout: 10))
        //   XCTAssertTrue(app.staticTexts["Second seeded message"].exists)
    }

    // ---- send, with the echo reconciled ------------------------------------------------------

    func testASentMessageAppearsOnceNotTwice() throws {
        throw XCTSkip(Self.navigationSkipReason)
        // Re-enable once openCurrentBook() navigates again. Kept for reference — the polling
        // logic below (not a single synchronous count) is a real, separate fix in its own right:
        // BookDetailView's ForEach keys on Message.id, and SendReconciler.replaceOptimistic swaps
        // the array element's id (the local clientId) for the server's new UUID at the same
        // index, so SwiftUI's diffing can legitimately show both views for one transition frame.
        // A real #35 regression looks different: the count STAYS at 2 because a second MESSAGE
        // was appended, not because a view is still finishing an animation.
        //
        //   launch()
        //   openCurrentBook()
        //   let body = "hermetic send \(Int(Date().timeIntervalSince1970))"
        //   let field = app.textViews["messageTextField"]
        //   field.tap()
        //   field.typeText(body)
        //   app.buttons["sendButton"].tap()
        //   XCTAssertTrue(app.staticTexts[body].waitForExistence(timeout: 10), "the sent message never appeared")
        //   let bubbles = app.staticTexts.matching(identifier: body)
        //   let deadline = Date().addingTimeInterval(3)
        //   while bubbles.count > 1 && Date() < deadline { usleep(100_000) }
        //   XCTAssertEqual(bubbles.count, 1, "the optimistic bubble and its confirmation both rendered and neither went away")
    }

    // ---- pure client UI ----------------------------------------------------------------------

    func testTheEmojiPickerRendersItsGridAndSwitchesCategory() throws {
        throw XCTSkip(Self.navigationSkipReason)
        // Re-enable once openCurrentBook() navigates again:
        //   launch()
        //   openCurrentBook()
        //   let message = app.staticTexts["First seeded message"]
        //   XCTAssertTrue(message.waitForExistence(timeout: 10))
        //   message.press(forDuration: 0.6)
        //   let plus = app.buttons["addEmojiReactionButton"]
        //   XCTAssertTrue(plus.waitForExistence(timeout: 5), "Reaction bar's + button never appeared")
        //   plus.tap()
        //   XCTAssertTrue(app.buttons["🥰"].waitForExistence(timeout: 10), "Emoji grid never rendered")
        //   app.buttons["🍔"].firstMatch.tap()
        //   XCTAssertTrue(app.buttons["🍕"].waitForExistence(timeout: 5), "switching category did not change the grid")
        //   app.buttons["Cancel"].firstMatch.tap()
        //   XCTAssertFalse(app.buttons["🍕"].waitForExistence(timeout: 3), "the picker never dismissed")
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
