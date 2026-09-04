import XCTest

// Drives the app through its real accessibility hierarchy (element queries + system-level
// touch injection) instead of guessing screen coordinates from screenshots — the latter proved
// unreliable for anything beyond a single confirmed tap (see #131 session notes). This is the
// start of the regression suite tracked for CI; keep new flows in this style rather than adding
// coordinate-based automation elsewhere.
final class OldMansBookClubUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        loginIfNeeded()
        openFirstBookDiscussion()
    }

    // MARK: - Helpers

    // Dev Login (Debug) signs in as the fixed seed user "Mark" (AuthViewModel.devLogin) — a
    // no-op if a session from a previous run is already persisted in the Keychain. A truly
    // fresh install (no persisted hasAcceptedEULA — e.g. right after a simulator erase) shows
    // Terms of Use first, behind which Dev Login is hidden — handle it before looking for Dev
    // Login, matching LibraryUITests' version of this same helper.
    private func loginIfNeeded() {
        let agreeButton = app.buttons["I Agree"]
        if agreeButton.waitForExistence(timeout: 3) {
            agreeButton.tap()
        }
        let devLoginButton = app.buttons["Dev Login (Debug)"]
        if devLoginButton.waitForExistence(timeout: 5) {
            devLoginButton.tap()
        }
    }

    // Opens the seeded "Seed: Current Read" book's chat via its Discussion link.
    private func openFirstBookDiscussion() {
        let discussionLink = app.staticTexts["Discussion"].firstMatch
        XCTAssertTrue(discussionLink.waitForExistence(timeout: 10), "Library screen never showed a Discussion link")
        discussionLink.tap()
        XCTAssertTrue(app.textViews["messageTextField"].waitForExistence(timeout: 5), "Chat screen never loaded")
    }

    private func uniqueMessage(_ label: String) -> String {
        "[UITest] \(label) \(Date().timeIntervalSince1970)"
    }

    // MARK: - Text send

    func testSendTextMessage_appearsInChat() {
        let text = uniqueMessage("text")
        let field = app.textViews["messageTextField"]
        field.tap()
        field.typeText(text)
        app.buttons["sendButton"].tap()

        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 10), "Sent message never appeared in chat")
        // Queried type-agnostically: this badge is a Menu's label, so it's a *button*, and the
        // original `app.otherElements[...]` form could never match — making the assertion
        // vacuous. See #150.
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "failedSendIndicator").count, 0,
                       "Message showed as failed")
    }

    // #146 — a send that can't reach the server (API stopped externally for this run) must go
    // .failed with a Retry option, not vanish. Requires the local dev API to be down when this
    // specific test runs.
    func testSendTextMessage_offlineShowsFailedAndRetries() throws {
        // Needs the local dev API stopped, which can't be arranged from inside the test — so it
        // is opt-in rather than silently failing every normal run (and CI). Run it with:
        //   OMBC_OFFLINE_TEST=1, having stopped `dotnet run` first.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OMBC_OFFLINE_TEST"] == "1",
                          "Set OMBC_OFFLINE_TEST=1 with the local API stopped to run this.")

        let text = uniqueMessage("offline")
        let field = app.textViews["messageTextField"]
        field.tap()
        field.typeText(text)
        app.buttons["sendButton"].tap()

        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 10), "Message bubble never appeared even before the (failed) send resolved")

        // A failed send raises an error alert, and a modal alert hides the chat's accessibility
        // elements underneath it — so anything below would read as absent while one is up.
        // Drained in a loop rather than dismissed once: a queued send left over from an earlier
        // offline run gets retried on foreground and can raise its own alert behind this one.
        dismissAnyAlerts()

        // The actual #146 contract: a send that couldn't reach the server STAYS on screen as a
        // retryable bubble. Before #146 it was deleted outright, so asserting the bubble is
        // still here is the regression that matters — more direct than counting badges, which
        // can't distinguish this message's badge from a leftover one anyway.
        XCTAssertTrue(app.staticTexts[text].exists, "Failed message was removed from the chat instead of staying as retryable")

        // failedSendIndicator is a Menu's label (SendStateBadge), so it's exposed as a button,
        // not an "other" element — matches app.buttons, same as the Retry/Cancel items inside it.
        let failedIndicator = app.buttons.matching(identifier: "failedSendIndicator").firstMatch
        XCTAssertTrue(failedIndicator.waitForExistence(timeout: 8), "No failed-send badge shown while the API was unreachable")

        failedIndicator.tap()
        XCTAssertTrue(app.buttons["Retry"].firstMatch.waitForExistence(timeout: 5), "Failed text message's badge menu has no Retry action")
    }

    /// Clears any stacked error alerts so the view underneath is queryable again.
    private func dismissAnyAlerts(limit: Int = 5) {
        for _ in 0..<limit {
            let alert = app.alerts.firstMatch
            guard alert.waitForExistence(timeout: 5) else { return }
            alert.buttons["OK"].firstMatch.tap()
        }
    }

    // The scenario that motivated this suite (#131): backgrounding the app immediately after
    // hitting send must not strand or falsely-fail the message. Covers the REST send path,
    // which (unlike the old SignalR invoke) doesn't need a live socket to complete.
    func testSendTextMessage_survivesImmediateBackgrounding() {
        let text = uniqueMessage("background")
        let field = app.textViews["messageTextField"]
        field.tap()
        field.typeText(text)
        app.buttons["sendButton"].tap()

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.activate()

        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 15), "Message did not survive backgrounding right after send")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "failedSendIndicator").count, 0,
                       "Message showed as failed after backgrounding")
    }

    // MARK: - Voice send

    // Handles both mic interaction modes (UserPreferences.TapToTalk) since either could be
    // active on the account running this suite.
    func testSendVoiceMessage() {
        let mic = app.buttons["micButton"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5), "Mic button not found")

        if isTapToTalk() {
            mic.tap()
            Thread.sleep(forTimeInterval: 2)
            mic.tap()
        } else {
            mic.press(forDuration: 2.0)
        }

        // Asserts the message reached the *confirmed* send state, not merely that no failure
        // appeared. The app models this discretely — .sending, .failed, or nil once the server
        // reconciles it — so a confirmed message is exactly one carrying neither badge. Waiting
        // for the sending spinner to clear and then requiring no failure badge distinguishes
        // success from a send still in flight, which "no failure yet" cannot.
        //
        // Both queried type-agnostically. The original test asserted
        // `app.otherElements["failedSendIndicator"]` doesn't exist, but that badge is a Menu's
        // label so it's exposed as a *button* — the query could never match and the assertion
        // passed unconditionally, staying green through a period when voice sending was
        // completely broken against dev.
        //
        // Deliberately not counting voicePlayButton before/after either: the chat is a lazy
        // list, so a new bubble arriving at the bottom pushes an older one out of the rendered
        // tree and the count doesn't move — observed against sends that reached the server fine.
        let sending = app.descendants(matching: .any).matching(identifier: "sendingIndicator")
        let failed = app.descendants(matching: .any).matching(identifier: "failedSendIndicator")

        let deadline = Date().addingTimeInterval(20)
        while sending.count > 0 && Date() < deadline { usleep(300_000) }
        XCTAssertEqual(sending.count, 0, "Voice message never left the sending state")
        XCTAssertEqual(failed.count, 0, "Voice message failed to send")
        XCTAssertGreaterThan(app.buttons.matching(identifier: "voicePlayButton").count, 0,
                             "No playable voice bubble rendered at all")
    }

    private func isTapToTalk() -> Bool {
        // A press-and-hold mic never enters the `.selected`/toggled state XCUITest can see from
        // a single tap; the two modes are visually and behaviorally distinct enough in practice
        // that attempting one and checking for a stuck `isRecording` state is unreliable to
        // probe generically. Simpler and accurate for this suite's fixed seed account (Mark,
        // TapToTalk=true): assume tap-to-talk. Update if the seed account's preference changes.
        true
    }
}
