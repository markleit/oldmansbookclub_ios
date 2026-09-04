import XCTest

/// Dismisses the iOS permission alerts that appear on a CLEAN install.
///
/// These tests used to run only against a simulator where permission had already been granted at
/// some point by hand, so nothing dismissed them — and the moment the regression script started
/// uninstalling the app between lanes (which it must, or a session from one lane poisons the
/// next), every test failed at "Library screen never showed a Discussion link". The alert was
/// sitting on top of the login screen the whole time, swallowing the taps.
///
/// SpringBoard is queried directly rather than using `addUIInterruptionMonitor`, which only fires
/// on the NEXT interaction with the app and so races the very tap it is supposed to unblock.
enum SystemAlerts {
    private static let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    /// Answers whatever permission alert is up, if any. Cheap to call and safe when none is
    /// showing — pass a short timeout when you are only checking.
    static func dismissAny(timeout: TimeInterval = 5) {
        // Wait for an ALERT once, not for each button label in turn — checking four labels with a
        // five-second timeout each would add twenty seconds to every setUp on the common path
        // where no alert is showing at all.
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: timeout) else { return }

        // "Allow" first: a test that needs a permission is better off having it, and notifications
        // are the prompt that actually covers the login screen. "While Using the App" is the
        // microphone and local-network wording, which the voice and device lanes need.
        for label in ["Allow", "Allow While Using App", "OK", "Continue"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            // A clean install can queue several in a row (notifications, then local network).
            dismissAny(timeout: 2)
            return
        }
    }
}
