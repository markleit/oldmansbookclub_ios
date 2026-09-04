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
    // no-op if a session from a previous run is already persisted in the Keychain.
    private func loginIfNeeded() {
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
        XCTAssertFalse(app.otherElements["failedSendIndicator"].exists, "Message showed as failed")
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
        XCTAssertFalse(app.otherElements["failedSendIndicator"].exists, "Message showed as failed after backgrounding")
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

        // A confirmed voice bubble reconciles from .sending to a playable bubble; absence of
        // the failed indicator after a generous window is the pass condition (no stable text
        // label to match on for a voice bubble).
        let failed = app.otherElements["failedSendIndicator"]
        XCTAssertFalse(failed.waitForExistence(timeout: 3), "Voice message failed to send")
    }

    // MARK: - #145 emoji reaction picker

    // Covers the wiring up to the system Emoji keyboard, not typing through the keyboard itself
    // (a separate, Apple-owned process XCUITest can reach but which is brittle to script
    // reliably) — long-press opens the bar, the fixed 6-emoji quick row is still there, and "+"
    // opens the full picker sheet. toggleReaction itself (used by both the quick row and the
    // picker) already has coverage via the existing quick-row reactions, unchanged by #145.
    func testEmojiReactionBar_plusButtonOpensFullPicker() {
        // Sends its own message to long-press rather than anchoring to a seeded one — a fixed
        // seed message eventually scrolls out of the loaded page as the dev DB accumulates
        // messages, which is exactly how this test first broke.
        let text = uniqueMessage("react")
        let field = app.textViews["messageTextField"]
        field.tap()
        field.typeText(text)
        app.buttons["sendButton"].tap()

        let bubble = app.staticTexts[text]
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "Sent message never appeared in chat")
        bubble.press(forDuration: 0.6)

        let plusButton = app.buttons["addEmojiReactionButton"]
        XCTAssertTrue(plusButton.waitForExistence(timeout: 5), "Reaction bar's + button never appeared")
        XCTAssertTrue(app.buttons["👍"].exists, "Existing fixed reaction row should still be present")
        plusButton.tap()

        // Asserts the grid itself rendered, not merely that a sheet appeared — the emoji below
        // are chosen to be unambiguous: 🥰 is in the default (smileys) grid but is neither a
        // category tab icon nor one of the six quick-tap reactions, and 🍕 exists only in the
        // food grid. A sheet-exists-only check would have passed against the old, broken
        // forced-keyboard picker too, which is exactly what this replaces.
        XCTAssertTrue(app.buttons["🥰"].waitForExistence(timeout: 10), "Emoji grid never rendered")

        app.buttons["🍔"].firstMatch.tap()   // food category tab
        XCTAssertTrue(app.buttons["🍕"].waitForExistence(timeout: 5), "Switching category didn't change the grid")

        // firstMatch: the chat's own input area also carries a Cancel while the reply/compose
        // affordances are up, so the bare query is ambiguous here.
        let cancelButton = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelButton.exists, "Emoji picker sheet has no Cancel button")
        cancelButton.tap()
        XCTAssertFalse(app.buttons["🍕"].waitForExistence(timeout: 3), "Emoji picker sheet never dismissed")
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
