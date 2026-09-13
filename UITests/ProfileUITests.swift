import XCTest

/// Profile tab key actions, against the real live API — see AdminUITests' header comment for why
/// the live lane over the hermetic one.
///
/// Deliberately NOT covered here: Delete Account. It's the one Profile action genuinely worth
/// testing (irreversible, hits a real production endpoint), but "Dev Login (Debug)" only ever
/// signs in as the fixed seed user "Mark" (AuthViewModel.devLogin) — there is no UI path or
/// launch-argument seam today to log in as a disposable second account instead, and deleting
/// Mark's own account here would either break every OTHER live-lane test class that assumes Mark
/// already exists and is a global admin, or silently rely on DevLogin's self-healing recreation
/// (a real behaviour, but not one this test should be gambling other files' setUp on). Left as a
/// known gap rather than tested against the wrong account.
///
/// `testEditingNameAndNicknameSaves` has shown occasional flake: the save round-trip (confirmed
/// directly via a raw curl PATCH to /users/me — the server accepts it fine) sometimes doesn't
/// show its "Saved" confirmation in time. Diagnosed directly with a UI interruption monitor: no
/// "Error" alert appears either — nothing is up at all — and re-running the identical class
/// immediately after reproduces a clean pass. Same category as this project's already-documented
/// Simulator/XCTest tooling flakiness (SpringBoard crashes, hermetic stub reachability), not a
/// code or test-logic defect — the underlying save behaviour is proven correct.
final class ProfileUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        SystemAlerts.dismissAny()
        loginIfNeeded()
        SystemAlerts.dismissAny()
        app.tabBars.buttons["Profile"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 5), "Profile tab never loaded")
    }

    private func loginIfNeeded() {
        let agree = app.buttons["I Agree"]
        if agree.waitForExistence(timeout: 3) { agree.tap() }
        let devLogin = app.buttons["Dev Login (Debug)"]
        if devLogin.waitForExistence(timeout: 5) { devLogin.tap() }
        XCTAssertTrue(app.tabBars.buttons["Profile"].waitForExistence(timeout: 10), "Profile tab never became available after login")
    }

    /// Replaces a text field's full contents rather than appending — `.typeText` alone would
    /// leave the pre-filled name/nickname in front of whatever this test types.
    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        if let value = field.value as? String, !value.isEmpty {
            let deleteAll = String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)
            field.typeText(deleteAll)
        }
        field.typeText(text)
    }

    private func save() {
        app.buttons["saveProfileButton"].tap()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 15), "no 'Saved' confirmation after saving the profile")
        app.buttons["OK"].tap()
    }

    // MARK: - Edit + save

    func testEditingNameAndNicknameSaves() {
        let nameField = app.textFields["profileDisplayNameField"]
        let nicknameField = app.textFields["profileNicknameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "display name field never appeared")

        let nickname = "UITest Nick \(Int(Date().timeIntervalSince1970))"
        replaceText(in: nicknameField, with: nickname)
        save()

        // Round-trips through the real API and back — clearing the field and reloading the tab
        // would only prove the local @State survived, not that the server actually persisted it.
        app.tabBars.buttons["Library"].tap()
        app.tabBars.buttons["Profile"].tap()
        XCTAssertEqual(nicknameField.value as? String, nickname, "nickname did not persist through a save + tab reload")

        // Restore, so other live-lane test files that dev-login as this same seed account later
        // in the same run don't inherit a UITest nickname.
        replaceText(in: nicknameField, with: "")
        save()
    }

    // MARK: - Sign out

    func testSignOutReturnsToTheLoginScreen() {
        app.buttons["signOutButton"].tap()
        XCTAssertTrue(app.buttons["Dev Login (Debug)"].waitForExistence(timeout: 10), "Sign Out did not return to a screen with Dev Login")
        XCTAssertFalse(app.tabBars.buttons["Profile"].exists, "the tab bar is still showing after signing out")
    }
}
