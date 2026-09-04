import XCTest

/// Dismisses the iOS permission alerts that appear on a CLEAN install.
///
/// These tests used to run only against a simulator where permission had already been granted at
/// some point by hand, so nothing dismissed them — and the moment the regression script started
/// uninstalling the app between lanes (which it must, or a session from one lane poisons the
/// next), they began failing.
///
/// **Call it AFTER logging in, not just before.** The notification prompt is triggered by push
/// registration, which happens once the user is authenticated — so on a clean install it lands a
/// second or two INTO the first screen, on top of whatever the test has just opened. The symptom
/// is bizarre: the tap on a menu button registers, the popover opens, the alert appears over it,
/// XCUITest auto-dismisses the alert (taking the popover with it), and the next tap lands on
/// nothing. The failure is then reported against the menu item, several steps from the cause.
///
/// SpringBoard is queried directly rather than using `addUIInterruptionMonitor`, which only fires
/// on the NEXT interaction with the app and so races the very tap it is supposed to unblock.
enum SystemAlerts {
    private static let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    /// Answers whatever permission alert is up, if any. Cheap to call and safe when none is
    /// showing — pass a short timeout when you are only checking. Returns whether it actually
    /// dismissed something, which matters at a call site where an alert eating the interaction
    /// underneath it (see below) means that interaction needs to be retried, not just followed.
    @discardableResult
    static func dismissAny(timeout: TimeInterval = 5) -> Bool {
        // Wait for an ALERT once, not for each button label in turn — checking four labels with a
        // five-second timeout each would add twenty seconds to every setUp on the common path
        // where no alert is showing at all.
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: timeout) else { return false }

        // "Allow" first: a test that needs a permission is better off having it, and notifications
        // are the prompt that actually covers the login screen. "While Using the App" is the
        // microphone and local-network wording, which the voice and device lanes need.
        for label in ["Allow", "Allow While Using App", "OK", "Continue"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            // A clean install can queue several in a row (notifications, then local network).
            dismissAny(timeout: 2)
            return true
        }
        return false
    }

    /// For an interaction that can trigger a FIRST-USE system permission prompt (microphone,
    /// speech recognition, camera, photo library) — the alert is requested lazily, mid-gesture,
    /// not at a predictable point in `setUp` the way the notification prompt is. It can appear
    /// exactly while a multi-second gesture like a long-press is in flight, which does not just
    /// delay the gesture — it eats it: the alert steals the touch-up, the app's press-state
    /// callback never fires, and nothing happens at all. No error, no crash, just silence, which
    /// is indistinguishable on screen from the feature being broken.
    ///
    /// The fix is not "dismiss before" (the alert may not exist yet — first use IS the trigger)
    /// or "dismiss after" alone (the gesture already failed by then) — it is retry-after-permission:
    /// attempt once, and if an alert shows up as a RESULT, dismiss it and attempt exactly once
    /// more now that the permission decision is already made and cannot interrupt a second time.
    static func performRetryingPermissionPrompt(_ action: () -> Void) {
        action()
        if dismissAny(timeout: 3) {
            action()
        }
    }
}
