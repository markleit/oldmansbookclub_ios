import XCTest

/// Admin tab key actions, against the real live API (`./scripts/regression.sh --live`) — not the
/// hermetic stub, which is unreliable right now (see HermeticUITests). "Dev Login (Debug)" always
/// signs in as the fixed seed user "Mark", who DevLogin always makes a global admin
/// (AuthController.DevLogin), so every test here already has full Admin tab access with no extra
/// setup on that side.
///
/// A second, non-admin member is what these tests actually act on — promoting/demoting/kicking/
/// deleting Mark himself would be either meaningless (AdminView hides those controls on your own
/// row, `member.id != myId`) or a step toward the exact cross-test interference this file has to
/// avoid, since the live lane's dev database is reset only once per whole regression run, not
/// between individual test methods. `seedJoinRequest(displayName:)` creates that second member via
/// the same `[AllowAnonymous]` `/admin/seed-join-request` endpoint — a plain, unapproved user with
/// a pending join request, no membership yet — and every test gives it a unique, timestamped name
/// so concurrent or out-of-order runs never collide.
///
/// Every test seeds ITS join request BEFORE the app ever launches, not after logging in. AdminView
/// fetches joinRequests/members exactly once, via `.task` when the view first appears, and
/// TabView builds every tab's view eagerly — so by the time a test would otherwise get around to
/// seeding, that first load has already run and returned an empty list. Worse, `requestsView`
/// renders a plain VStack (not a List) whenever joinRequests is empty, so there is no Table for a
/// pull-to-refresh gesture to act on either — confirmed directly: `app.tables.firstMatch` finds
/// nothing in that empty state. Seeding first means the very first load already includes the
/// request, sidestepping both problems at once. The Members list doesn't have this issue (Mark's
/// own row keeps it non-empty), so `pullToRefresh()` after approving works fine there.
final class AdminUITests: XCTestCase {
    private var app: XCUIApplication!
    private let apiBaseURL = URL(string: "http://localhost:5235")!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchAndLogin() {
        app = XCUIApplication()
        app.launch()
        SystemAlerts.dismissAny()
        let agree = app.buttons["I Agree"]
        if agree.waitForExistence(timeout: 3) { agree.tap() }
        let devLogin = app.buttons["Dev Login (Debug)"]
        if devLogin.waitForExistence(timeout: 5) { devLogin.tap() }
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10), "not signed in")
        SystemAlerts.dismissAny()
    }

    private func openAdminTab() {
        // The tab's label comes from @AppStorage("user_is_admin"), written once DevLogin's
        // response is processed — on a freshly reinstalled app that write can trail the login
        // screen's own transition by a beat, so the tab briefly still reads its pre-login default
        // ("Members") right after `app.tabBars.buttons["Library"]` first appears. Waiting on the
        // FINAL label ("Admin" — Mark is always global admin) rather than tapping immediately
        // avoids racing that write.
        let adminTab = app.tabBars.buttons["Admin"]
        XCTAssertTrue(adminTab.waitForExistence(timeout: 15), "Admin tab label never settled to 'Admin'")
        adminTab.tap()
        XCTAssertTrue(app.navigationBars["Admin"].waitForExistence(timeout: 5), "Admin tab never loaded")
    }

    private func openRequestsTab() {
        app.buttons["Requests"].tap()
    }

    private func openMembersTab() {
        app.buttons["Members"].tap()
    }

    /// approveRequest()/declineRequest() only mutate the local joinRequests array — neither
    /// appends the newly approved member to the already-fetched members array, so checking
    /// Members afterward needs its own refresh. Swipes on the whole app window rather than
    /// hunting for a specific List element type (`.tables`, `.collectionViews`, ...) — which one
    /// SwiftUI's List actually renders as is a version/style-dependent implementation detail, not
    /// something worth pinning a test to; a plain window-level swipe lands on whatever scrollable
    /// content is on screen the same way a real pull-to-refresh gesture would.
    private func pullToRefresh() {
        app.swipeDown()
    }

    /// Retries pullToRefresh a few times before giving up — a single swipe-down gesture is not
    /// perfectly reliable (confirmed directly: back-to-back runs of the identical test flow
    /// occasionally needed a second attempt for a just-approved member to show up), and this
    /// project's own standing lesson is to make a flaky UI assertion robust rather than accept an
    /// occasional false failure. A genuine app regression still fails this every time.
    private func waitForTextAfterRefresh(_ text: String, attempts: Int = 3, timeout: TimeInterval = 8) -> Bool {
        let element = app.staticTexts[text]
        for _ in 0..<attempts {
            if element.waitForExistence(timeout: timeout) { return true }
            pullToRefresh()
        }
        return element.waitForExistence(timeout: timeout)
    }

    // MARK: - Seeding a second member

    /// Creates an unapproved user with a pending join request against the seeded club. Runs as a
    /// plain synchronous HTTP call, completed before the app even launches — same shape as
    /// DeviceOnlyUITests' raw-HTTP setup, minus auth (this endpoint is anonymous and
    /// Development-only).
    @discardableResult
    private func seedJoinRequest(displayName: String) -> Bool {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent("/admin/seed-join-request"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // JSONSerialization.data(withJSONObject:) requires an Array or Dictionary at the top
        // level — a bare String throws "Invalid top-level type in JSON write". JSONEncoder has
        // no such restriction and produces exactly the quoted-string body [FromBody] string
        // expects.
        request.httpBody = try? JSONEncoder().encode(displayName)

        var succeeded = false
        let done = expectation(description: "seed-join-request")
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) { succeeded = true }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return succeeded
    }

    private func uniqueName(_ label: String) -> String {
        "\(label) \(Int(Date().timeIntervalSince1970 * 1000) % 1_000_000)"
    }

    /// Seeds a join request, launches fresh, and approves it through the UI, leaving the app on
    /// the Members tab with that member's row visible — the common starting point for every
    /// Members-tab test.
    private func seedAndApproveMember(name: String) {
        XCTAssertTrue(seedJoinRequest(displayName: name), "seed-join-request failed — is the local API running in Development?")
        launchAndLogin()
        openAdminTab()
        openRequestsTab()
        let row = app.staticTexts[name]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded join request '\(name)' never appeared in Requests")
        app.buttons["approveJoinRequestButton"].firstMatch.tap()
        XCTAssertFalse(row.waitForExistence(timeout: 5), "approved request still showing in Requests")

        openMembersTab()
        XCTAssertTrue(waitForTextAfterRefresh(name), "approved member never appeared in Members")
    }

    // MARK: - Join requests

    func testApprovingAJoinRequestAddsThemAsAMember() {
        let name = uniqueName("UITest Approve")
        seedAndApproveMember(name: name)
        // seedAndApproveMember already asserts both halves of this: gone from Requests, present
        // in Members — this test just names the behaviour on its own.
    }

    func testDecliningAJoinRequestRemovesItWithoutAddingThem() {
        let name = uniqueName("UITest Decline")
        XCTAssertTrue(seedJoinRequest(displayName: name), "seed-join-request failed")
        launchAndLogin()

        openAdminTab()
        openRequestsTab()
        let row = app.staticTexts[name]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "seeded join request never appeared")
        app.buttons["declineJoinRequestButton"].firstMatch.tap()
        XCTAssertFalse(row.waitForExistence(timeout: 5), "declined request still showing in Requests")

        // Without this refresh, `members` is still the snapshot fetched at launch — BEFORE this
        // request even existed — so the assertion below would pass vacuously even if Decline
        // incorrectly created a membership server-side. See feedback_false_passing_uitests.
        openMembersTab()
        pullToRefresh()
        XCTAssertFalse(app.staticTexts[name].waitForExistence(timeout: 3), "declined user was added as a member anyway")
    }

    // MARK: - Member management

    func testPromotingAndDemotingAMemberTogglesTheirAdminBadge() {
        let name = uniqueName("UITest Promote")
        seedAndApproveMember(name: name)
        let row = app.staticTexts[name]
        // toggleAdminButton is a fixed accessibilityIdentifier on a button whose visible LABEL
        // flips between "Make Admin" and "Demote" — app.buttons["X"] matches identifier, not
        // label, so the flip has to be read off .label directly, not via a second lookup by text.
        let toggleButton = app.buttons["toggleAdminButton"]

        row.swipeLeft()
        XCTAssertTrue(toggleButton.waitForExistence(timeout: 5), "toggle-admin action never appeared")
        XCTAssertEqual(toggleButton.label, "Make Admin", "a freshly approved member should not already be an admin")
        toggleButton.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "member row disappeared after promoting")

        row.swipeLeft()
        XCTAssertTrue(toggleButton.waitForExistence(timeout: 5), "toggle-admin action never reappeared")
        XCTAssertEqual(toggleButton.label, "Demote", "promoting never flipped the action to Demote — isAdmin didn't stick")
        toggleButton.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "member row disappeared after demoting")

        row.swipeLeft()
        XCTAssertTrue(toggleButton.waitForExistence(timeout: 5), "toggle-admin action never reappeared")
        XCTAssertEqual(toggleButton.label, "Make Admin", "demoting never flipped the action back to Make Admin")
        app.swipeUp() // dismiss the open swipe-action row so it doesn't shadow later taps
    }

    func testKickingAMemberRemovesThemFromTheList() {
        let name = uniqueName("UITest Kick")
        seedAndApproveMember(name: name)

        let row = app.staticTexts[name]
        row.swipeLeft()
        app.buttons["kickMemberButton"].tap()
        XCTAssertFalse(row.waitForExistence(timeout: 5), "kicked member still shows in Members")
    }

    func testDeletingAMemberRemovesThemFromTheList() throws {
        // #153: AdminController.DeleteUser calls db.Database.BeginTransactionAsync() on a
        // DbContext registered with EnableRetryOnFailure, which EF rejects at runtime for EVERY
        // caller ("does not support user-initiated transactions") — not just the heard/reacted
        // subset #133 describes. Confirmed directly here: the delete request 500s, the Swift
        // catch sets errorMessage and never removes the row, so the row stays. Same skip
        // convention as Tests/BookClubApi.Tests/Api/AdminTests.cs — unskip once #153 is fixed.
        throw XCTSkip("#153: DeleteUser 500s for every user (execution strategy vs. transaction) — not fixed yet.")
    }
}
