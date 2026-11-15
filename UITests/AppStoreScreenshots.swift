import XCTest

/// App Store screenshots (not a regression test). Drives the app through the staged screenshot club
/// (`scripts/appstore/stage.py` on the local dev API) and saves each screen as a kept attachment,
/// which `scripts/appstore/capture.sh` exports and `compose.py` frames with captions.
///
/// Skipped unless OMBC_SHOTS_CLUB_ID is set (pass TEST_RUNNER_OMBC_SHOTS_CLUB_ID to xcodebuild),
/// so it never runs in CI or a normal test run.
final class AppStoreScreenshots: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true   // a missed shot shouldn't cost the rest
    }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 1.2)   // let animations and images settle
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testCaptureAppStoreScreens() throws {
        let env = ProcessInfo.processInfo.environment
        guard let clubId = env["OMBC_SHOTS_CLUB_ID"] else {
            throw XCTSkip("App Store screenshots only run with OMBC_SHOTS_CLUB_ID (scripts/appstore/capture.sh)")
        }
        app = XCUIApplication()
        app.launchArguments += [
            "-debugServerBaseURL", env["OMBC_SHOTS_API"] ?? "http://localhost:5235",
            "-hasAcceptedEULA_v2", "YES",
            "-uiTestFreshLocalState", "YES",
            "-club_id", clubId,
        ]
        app.launch()
        SystemAlerts.dismissAny()
        let devLogin = app.buttons["Dev Login (Debug)"]
        if devLogin.waitForExistence(timeout: 10) { devLogin.tap() }
        // The notification permission prompt comes a moment after sign-in; answer it before any shot.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 12) { allow.tap() }
        SystemAlerts.dismissAny()

        // 1. Library
        XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 30), "Library never showed the staged club")
        Thread.sleep(forTimeInterval: 3)   // covers load
        shot("library")

        // 2. The chat: lands at the newest, voice messages, and "↑ Unread messages" for the backlog
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Discussion'")).firstMatch.tap()
        XCTAssertTrue(app.textViews["messageTextField"].waitForExistence(timeout: 20), "chat never opened")
        _ = element("newMessageAboveChip").waitForExistence(timeout: 10)
        Thread.sleep(forTimeInterval: 2)
        shot("chat-newest")

        // 3. Tap the pill: the oldest unread — the photo, a reply and reactions
        if element("newMessageAboveChip").exists {
            element("newMessageAboveChip").tap()
            Thread.sleep(forTimeInterval: 2)
        }
        shot("chat-oldest")

        // 4. Long-press a message: quick reactions, Reply, Save
        let frank = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Call me Frank'")).firstMatch
        if frank.waitForExistence(timeout: 5) {
            frank.press(forDuration: 0.8)
            Thread.sleep(forTimeInterval: 1.2)
            shot("chat-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()   // dismiss
            Thread.sleep(forTimeInterval: 1)
        }

        // 5. A voice message playing: the player and its speed control
        let play = app.buttons.matching(identifier: "voicePlayButton").firstMatch
        if play.waitForExistence(timeout: 5) {
            play.tap()
            Thread.sleep(forTimeInterval: 2.5)
            shot("voice-playing")
            play.tap()   // pause
            Thread.sleep(forTimeInterval: 1)
        }

        // 6. Recording (tap-to-talk is on for the staged viewer): one tap starts it
        let mic = element("micButton")
        if mic.waitForExistence(timeout: 5) {
            mic.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let ok = springboard.alerts.buttons["Allow"].firstMatch
            if ok.waitForExistence(timeout: 3) { ok.tap(); mic.tap() }
            Thread.sleep(forTimeInterval: 4)
            shot("recording")
            mic.tap()   // stop (it sends a few seconds of silence to the staged chat)
        }
    }
}
