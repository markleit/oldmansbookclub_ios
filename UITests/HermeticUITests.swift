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
///
/// If iterating on this file with `xcodebuild test` directly instead of through
/// `scripts/regression.sh`, uninstall the app AND reset the Keychain before every run —
/// `xcrun simctl uninstall <udid> com.markleit.oldmansbookclub.dev && xcrun simctl keychain
/// <udid> reset` (regression.sh's own `reset_simulator_state()` already does both). Keychain
/// survives a plain uninstall, and the stub's dev-login always returns the exact same fixed
/// tokens ("stub-access-token"/"stub-refresh-token") — so a stale Keychain entry from an earlier
/// run looks perpetually valid, `AuthViewModel.init()` sets `isAuthenticated = true` before Dev
/// Login is ever tapped, and `TokenStore.shared.userId` (UserDefaults-only, wiped by a plain
/// uninstall) stays nil for the rest of the session. Confirmed directly this way once: every
/// screen that doesn't read `userId` rendered fine regardless, while `sendMessage()`'s
/// `guard let userId = TokenStore.shared.userId` failed with "Session error" — nothing wrong with
/// the app, purely a gap in ad hoc local iteration.
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
        launch()
        openCurrentBook()
        let body = "hermetic send \(Int(Date().timeIntervalSince1970))"
        let field = app.textViews["messageTextField"]
        field.tap()
        field.typeText(body)
        let sendButton = app.buttons["sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "sendButton never appeared after typing")
        sendButton.tap()
        XCTAssertTrue(app.staticTexts[body].waitForExistence(timeout: 10), "the sent message never appeared")
        // Polling, not a single synchronous count — BookDetailView's ForEach keys on Message.id,
        // and SendReconciler.replaceOptimistic swaps the array element's id (the local clientId)
        // for the server's new UUID at the same index, so SwiftUI's diffing can legitimately show
        // both views for one transition frame. A real #35 regression looks different: the count
        // STAYS at 2 because a second MESSAGE was appended, not because a view is still finishing
        // an animation.
        let bubbles = app.staticTexts.matching(identifier: body)
        let deadline = Date().addingTimeInterval(3)
        while bubbles.count > 1 && Date() < deadline { usleep(100_000) }
        XCTAssertEqual(bubbles.count, 1, "the optimistic bubble and its confirmation both rendered and neither went away")
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
        XCTAssertTrue(waitForDisappearance(app.buttons["🍕"]), "the picker never dismissed")
    }

    // #173 — iOS-keyboard model: a quick tap sends the emoji (the hold gesture must not eat taps);
    // press-and-hold opens the six tone variants; the chosen tone is remembered for THAT emoji only
    // and shows in the grid and on the quick reaction bar. Grid cells and quick-bar buttons are
    // looked up by identifier because a sent reaction adds a same-emoji pill to the chat behind.
    // Ends by restoring the default tone — the choice persists in UserDefaults across tests.
    func testSkinTonesArePressAndHoldAndRememberedPerEmoji() throws {
        launch()
        openCurrentBook()
        let message = app.staticTexts["First seeded message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))

        func openPeopleGrid() {
            message.press(forDuration: 0.6)
            let plus = app.buttons["addEmojiReactionButton"]
            XCTAssertTrue(plus.waitForExistence(timeout: 5), "Reaction bar's + button never appeared")
            plus.tap()
            XCTAssertTrue(app.buttons["🥰"].waitForExistence(timeout: 10), "Emoji grid never rendered")
            app.buttons["👋"].firstMatch.tap()   // People tab
            XCTAssertTrue(app.buttons["emoji.👍"].waitForExistence(timeout: 5), "People grid never rendered")
        }
        let cancel = app.buttons["Cancel"].firstMatch

        // A quick tap on a tone-able emoji still sends it and closes the picker.
        openPeopleGrid()
        app.buttons["emoji.👋"].tap()
        XCTAssertTrue(waitForDisappearance(cancel), "a quick tap on a tone-able emoji did not pick it")

        // Hold → variants → pick dark.
        openPeopleGrid()
        XCTAssertEqual(app.buttons["emoji.👍"].label, "👍")
        app.buttons["emoji.👍"].press(forDuration: 0.8)
        let dark = app.buttons["skinTone.5"]
        XCTAssertTrue(dark.waitForExistence(timeout: 5), "press-and-hold did not open the tone variants")
        dark.tap()
        XCTAssertTrue(waitForDisappearance(cancel), "choosing a tone did not pick the emoji")

        // Remembered for 👍 only: quick bar and grid show it; ✋ is untouched.
        message.press(forDuration: 0.6)
        let quickThumb = app.buttons["quickReaction.👍"]
        XCTAssertTrue(quickThumb.waitForExistence(timeout: 5))
        XCTAssertEqual(quickThumb.label, "👍🏿", "the quick bar's 👍 did not follow the tone chosen for it")
        XCTAssertEqual(app.buttons["quickReaction.❤️"].label, "❤️")
        app.buttons["addEmojiReactionButton"].tap()
        XCTAssertTrue(app.buttons["🥰"].waitForExistence(timeout: 10))
        app.buttons["👋"].firstMatch.tap()
        XCTAssertTrue(app.buttons["emoji.👍"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["emoji.👍"].label, "👍🏿", "the grid did not show 👍 in its remembered tone")
        XCTAssertEqual(app.buttons["emoji.✋"].label, "✋", "a tone chosen for 👍 leaked onto ✋")

        // A hold on an emoji without tones does nothing special — no variants appear.
        app.buttons["😀"].firstMatch.tap()   // Smileys tab
        app.buttons["emoji.😂"].press(forDuration: 0.8)
        XCTAssertFalse(app.buttons["skinTone.5"].waitForExistence(timeout: 2), "a non-tone emoji offered tones")

        // Restore the default for 👍.
        if cancel.exists { app.buttons["👋"].firstMatch.tap() } else { openPeopleGrid() }
        app.buttons["emoji.👍"].press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["skinTone.0"].waitForExistence(timeout: 5))
        app.buttons["skinTone.0"].tap()
    }

    /// Waits for an element to GO AWAY. `XCTAssertFalse(x.waitForExistence(...))` is not this: it
    /// returns true the instant the element is still on screen — e.g. a sheet mid-dismiss on a slow
    /// CI runner — so it failed a correct dismissal in CI while passing locally.
    // ---- photo viewer (#191) and Save to Photos (#193) ------------------------------------------

    private func openPhotoViewer() -> XCUIElement {
        let bubble = app.buttons["photoMessage"].firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "photo bubble never rendered")
        bubble.tap()
        let viewer = app.descendants(matching: .any)["fullScreenImage"].firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), "full-screen photo never opened")
        XCTAssertTrue(waitForValue(of: viewer, containing: "zoom=1.00"), "viewer didn't lay out at 1×")
        return viewer
    }

    private func waitForValue(of element: XCUIElement, containing text: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// The bug (#191): once zoomed, the photo couldn't be dragged, so its sides were unreachable.
    /// The viewer reports the visible horizontal slice of the photo ("visible=0.00-1.00" is the
    /// whole width), so this proves a zoomed photo pans all the way to each edge.
    func testAZoomedPhotoPansToBothEdgesAndPullsDownToClose() throws {
        try setMessages([["type": "Photo"], "after the photo"])
        launch()
        openCurrentBook()
        let viewer = openPhotoViewer()

        viewer.pinch(withScale: 3, velocity: 2)
        let zoomed = NSPredicate(format: "NOT (value CONTAINS 'zoom=1.00') AND NOT (value CONTAINS 'visible=0.00-1.00')")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: zoomed, object: viewer)], timeout: 5),
                       .completed, "pinch didn't zoom: \(viewer.value ?? "nil")")

        for _ in 0..<6 { viewer.swipeRight() }
        XCTAssertTrue(waitForValue(of: viewer, containing: "visible=0.00-"),
                      "a zoomed photo couldn't be panned to its left edge: \(viewer.value ?? "nil")")
        for _ in 0..<8 { viewer.swipeLeft() }
        XCTAssertTrue(waitForValue(of: viewer, containing: "-1.00"),
                      "a zoomed photo couldn't be panned to its right edge: \(viewer.value ?? "nil")")

        // Pull-down must not close a zoomed photo (it pans instead)…
        viewer.swipeDown()
        XCTAssertTrue(viewer.exists, "pulling down on a zoomed photo closed the viewer")

        // …double-tap returns to 1×, and then pull-down closes.
        viewer.doubleTap()
        XCTAssertTrue(waitForValue(of: viewer, containing: "zoom=1.00"), "double-tap didn't zoom back out")
        viewer.swipeDown()
        XCTAssertTrue(waitForDisappearance(viewer), "pull-down at 1× didn't close the viewer")
    }

    func testDoubleTapZoomsInOnAPhoto() throws {
        try setMessages([["type": "Photo"]])
        launch()
        openCurrentBook()
        let viewer = openPhotoViewer()
        viewer.doubleTap()
        let zoomed = NSPredicate(format: "NOT (value CONTAINS 'zoom=1.00')")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: zoomed, object: viewer)], timeout: 5),
                       .completed, "double-tap didn't zoom in")
        app.buttons["viewerClose"].tap()
        XCTAssertTrue(waitForDisappearance(viewer))
    }

    /// Messages' model: press-and-hold a photo → "Save to Photos". The bookmark action is
    /// "Bookmark" now, so the two never share a name.
    func testSaveToPhotosFromThePhotoMenu() throws {
        try setMessages([["type": "Photo"]])
        launch()
        openCurrentBook()
        let bubble = app.buttons["photoMessage"].firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 10))
        bubble.press(forDuration: 0.8)

        let save = app.buttons["Save to Photos"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "photo menu has no Save to Photos")
        XCTAssertTrue(app.buttons["Bookmark"].exists, "bookmark action should be named Bookmark")
        XCTAssertFalse(app.buttons["Save"].exists, "a bare 'Save' would be ambiguous next to Save to Photos")
        save.tap()
        // First use asks for add-only Photos access and the save carries on once it's answered;
        // with access already granted the toast shows at once and only lasts 2s — so watch for
        // either rather than waiting out an alert that may never come.
        let toast = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Saved to Photos'")).firstMatch
        // (Not SystemAlerts.dismissAny: after answering it waits 2s for a follow-up prompt, which
        // is exactly the toast's lifetime.)
        let photosAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        var sawToast = false
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && !sawToast {
            if toast.exists { sawToast = true; break }
            if photosAlert.exists, photosAlert.buttons["Allow"].exists { photosAlert.buttons["Allow"].tap() }
        }
        XCTAssertTrue(sawToast, "no Saved to Photos confirmation")
    }

    /// Text messages get no Save to Photos.
    func testTextMessagesHaveNoSaveToPhotos() throws {
        launch()
        openCurrentBook()
        let text = app.staticTexts["First seeded message"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Bookmark"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save to Photos"].exists)
    }

    /// The viewer's Share button opens the system sheet on the downloaded original.
    func testThePhotoViewerSharesTheImage() throws {
        try setMessages([["type": "Photo"]])
        launch()
        openCurrentBook()
        _ = openPhotoViewer()
        app.buttons["viewerShare"].tap()
        let sheetAppeared = app.otherElements["ActivityListView"].waitForExistence(timeout: 10)
            || app.buttons["Save Image"].waitForExistence(timeout: 2)
            || app.cells["Save Image"].exists
        XCTAssertTrue(sheetAppeared, "share sheet never appeared")
    }

    // ---- Saved Messages: open vs forward (#192) ------------------------------------------------

    private func setSaved(_ saved: [Any]) throws {
        try controlRequest(path: "/_stub/saved", method: "POST", jsonBody: saved)
    }

    private func openSavedMessages() {
        let menu = app.buttons["attachmentMenuButton"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let item = app.buttons["Saved Messages"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "+ menu has no Saved Messages")
        item.tap()
        XCTAssertTrue(app.navigationBars["Saved Messages"].waitForExistence(timeout: 10), "Saved Messages never opened")
    }

    /// The bug (#192): tapping a saved message forwarded it into the current chat and closed the
    /// sheet. Now it opens the photo, and Saved Messages is still there afterwards.
    func testTappingASavedPhotoOpensItInsteadOfForwarding() throws {
        try setSaved([["type": "Photo"]])
        launch()
        openCurrentBook()
        openSavedMessages()

        let open = app.buttons["savedOpen"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), "saved photo row never rendered")
        open.tap()
        let viewer = app.descendants(matching: .any)["fullScreenImage"].firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), "tapping a saved photo didn't open it")
        app.buttons["viewerClose"].tap()
        XCTAssertTrue(waitForDisappearance(viewer))
        XCTAssertTrue(app.navigationBars["Saved Messages"].exists, "Saved Messages closed — the tap forwarded instead of opening")
    }

    func testTappingSavedTextShowsItInFull() throws {
        let long = "A saved thought that is long enough to be cut off in the list row, so the detail screen has to show all of it — every last word."
        try setSaved([long])
        launch()
        openCurrentBook()
        openSavedMessages()

        let row = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'A saved thought'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["Saved Message"].waitForExistence(timeout: 5), "text detail never opened")
        XCTAssertTrue(app.staticTexts[long].exists, "detail doesn't show the full text")
        XCTAssertTrue(app.buttons["Copy"].exists)
    }

    /// Forward is separate: ↗ → pick any chat (this one pinned first) → confirm. The stub has no
    /// SignalR hub, so the send itself fails here — which also proves a failure is reported in
    /// Saved Messages instead of silently closing it. (A real forward is covered on device.)
    func testForwardAsksWhichChatThenConfirms() throws {
        try setSaved(["Forward me"])
        launch()
        openCurrentBook()
        openSavedMessages()

        let forward = app.buttons["savedForward"].firstMatch
        XCTAssertTrue(forward.waitForExistence(timeout: 10), "no Forward button on the saved row")
        forward.tap()
        XCTAssertTrue(app.navigationBars["Forward to…"].waitForExistence(timeout: 5), "chat picker never opened")
        XCTAssertTrue(app.buttons["forwardTo-Seed: Current Read"].waitForExistence(timeout: 10), "current chat not offered")
        let other = app.buttons["forwardTo-Seed: Future Read"]
        XCTAssertTrue(other.waitForExistence(timeout: 10), "other chats in the club not offered")

        other.tap()
        XCTAssertTrue(app.staticTexts["Forward to Seed: Future Read?"].waitForExistence(timeout: 5), "no confirmation before forwarding")
        let confirm = app.buttons["Forward"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.alerts["Couldn't Forward"].waitForExistence(timeout: 30), "a failed forward wasn't reported")
        app.alerts["Couldn't Forward"].buttons["OK"].tap()
        XCTAssertTrue(app.navigationBars["Saved Messages"].exists, "forwarding should leave you in Saved Messages")
    }

    // ---- playback speed −/+ (#190) --------------------------------------------------------------

    /// The slider stays; + / − step a quarter at a time and stop at the ends. Driven from Saved
    /// Messages, whose voice row shows the speed control without playing: the chat bubble's only
    /// appears DURING playback, and a CI simulator may stop playback (no audio device) and close
    /// the popover mid-test. Same VerticalSpeedSlider either way.
    func testSpeedButtonsStepAQuarterAndStopAtTheEnds() throws {
        try setSaved([["type": "Voice"]])
        launch()
        openCurrentBook()
        openSavedMessages()

        let bunny = app.buttons["Playback speed"].firstMatch
        XCTAssertTrue(bunny.waitForExistence(timeout: 10), "saved voice row has no speed control")
        bunny.tap()

        let value = app.staticTexts["speedValue"]
        let up = app.buttons["speedUp"], down = app.buttons["speedDown"]
        XCTAssertTrue(value.waitForExistence(timeout: 5), "speed popover never opened")

        // Start from a known place: down to the 1× floor (persisted rate may be anything).
        for _ in 0..<12 where down.isEnabled { down.tap() }
        XCTAssertEqual(value.label, "1×")
        XCTAssertFalse(down.isEnabled, "− should be disabled at 1×")

        up.tap()
        XCTAssertEqual(value.label, "1.25×")
        up.tap()
        XCTAssertEqual(value.label, "1.5×")
        down.tap()
        XCTAssertEqual(value.label, "1.25×")

        for _ in 0..<12 where up.isEnabled { up.tap() }
        XCTAssertEqual(value.label, "4×")
        XCTAssertFalse(up.isEnabled, "+ should be disabled at 4×")

        // Leave the persisted rate at 1× for whatever runs next.
        for _ in 0..<12 where down.isEnabled { down.tap() }
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    // ---- control API (talks to the host-level stub, not an in-process object) ----------------

    /// Each item is a text body, or e.g. `["type": "Photo"]` for a photo the stub serves itself.
    private func setMessages(_ messages: [Any]) throws {
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
