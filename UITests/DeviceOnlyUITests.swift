import XCTest

/// The four things a simulator genuinely cannot prove (#126, lane C).
///
/// Every one of these is here because the simulator's answer would be a false negative OR a false
/// positive, not because they are merely slower:
///
///   · a simulator cannot receive a real APNs push at all — `simctl push` injects a local payload,
///     which exercises handling and says nothing about delivery;
///   · a simulator's "background" is not iOS's — nothing is really suspended, so a send that would
///     die on a device completes happily;
///   · there is no microphone, and no audio route to change;
///   · the watchdog timing behind the open 0x8BADF00D scene-update crashes (#141, #142, #151)
///     only exists on real hardware.
///
/// Run with: ./scripts/regression.sh --device
///
/// Requires the device pointed at this Mac — Settings → Server (Debug) → Dev Machine — because
/// `localhost` on a phone is the phone. The whole class skips on a simulator rather than passing
/// vacuously, which is the failure mode that once hid a total send outage.
final class DeviceOnlyUITests: XCTestCase {
    private var app: XCUIApplication!

    /// The API as the DEVICE can reach it. Matches ServerEnvironment.devMachineURLString, and is
    /// overridable for a machine whose Wi-Fi filters mDNS (type `ipconfig getifaddr en0`'s answer).
    private var apiBaseURL: URL {
        let raw = ProcessInfo.processInfo.environment["OMBC_API_URL"] ?? "http://Marks-MacBook.local:5235"
        return URL(string: raw)!
    }

    override func setUpWithError() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("""
            Device-only. On a simulator these tests would pass without proving anything: no real \
            push can arrive, and nothing is genuinely suspended. Run ./scripts/regression.sh --device.
            """)
        #else
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        loginIfNeeded()
        #endif
    }

    private func loginIfNeeded() {
        let agree = app.buttons["I Agree"]
        if agree.waitForExistence(timeout: 3) { agree.tap() }
        let devLogin = app.buttons["Dev Login (Debug)"]
        if devLogin.waitForExistence(timeout: 5) { devLogin.tap() }
    }

    // MARK: - A second member, driven over HTTP

    /// Signs a second account in over the API and returns its bearer token.
    ///
    /// Deliberately raw HTTP rather than a second simulator running the app: this needs only to
    /// *cause* a push, and a second UI-driven client would add a boot, a login and a send — three
    /// more things that can fail for reasons unrelated to whether the notification arrives.
    private func signInSecondMember() throws -> String {
        let response = try post("/auth/dev-login", body: ["displayName": "Push Sender"], token: nil)
        return try XCTUnwrap(response["access_token"] as? String,
                             "dev-login did not return a token — is the API running in Development?")
    }

    private func firstBookId(token: String) throws -> String {
        let books = try getArray("/books", token: token)
        let book = try XCTUnwrap(books.first, "the second member sees no books — was the database seeded?")
        return try XCTUnwrap(book["id"] as? String)
    }

    private func sendMessage(bookId: String, body: String, token: String) throws {
        _ = try post("/books/\(bookId)/messages",
                     body: ["type": "Text", "body": body, "client_id": UUID().uuidString],
                     token: token)
    }

    // MARK: - Push delivery

    func testAMessageFromAnotherMemberArrivesAsAPushWhileBackgrounded() throws {
        let token = try signInSecondMember()
        let bookId = try firstBookId(token: token)
        let body = "[UITest] push \(Int(Date().timeIntervalSince1970))"

        // Background the app FIRST. A foregrounded app receives the message over SignalR and shows
        // no banner at all, so this ordering is the test.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)

        try sendMessage(bookId: bookId, body: body, token: token)

        // The banner is SpringBoard's, not the app's, so it has to be queried through SpringBoard.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let banner = springboard.otherElements.containing(.any, identifier: "Notification").firstMatch
        let arrived = banner.waitForExistence(timeout: 30)
            || springboard.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "[UITest] push")).firstMatch.exists

        XCTAssertTrue(arrived, """
            No push arrived within 30s. Check, in order: the device has notification permission; \
            the app registered a device token against THIS server (a token registered against \
            production will not be pushed by a dev API); and Apns:Enabled is not false in the \
            API's user-secrets — #120 sets it false so dev traffic cannot push real devices, \
            which also silences this test.
            """)
    }

    // MARK: - Background and return

    func testASendSurvivesBeingBackgroundedImmediately() throws {
        openFirstBookDiscussion()
        let field = app.textViews["messageTextField"]
        let body = "[UITest] background \(Int(Date().timeIntervalSince1970))"

        field.tap()
        field.typeText(body)
        app.buttons["sendButton"].tap()
        // Straight to the home screen — on a device this really does suspend the process, which
        // is the case #146's durable outbox and BackgroundTaskBox exist for. On a simulator this
        // line proves nothing, which is why the class skips there.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 5)

        app.activate()

        let sent = app.staticTexts[body]
        XCTAssertTrue(sent.waitForExistence(timeout: 20),
                      "the message did not survive an immediate background — it should be sent, or at minimum still present and retryable")
    }

    func testTheAppRecoversFromAServerOutageWithoutBeingRelaunched() throws {
        // #121, which is still open precisely because it can only be answered here. Left as a
        // documented manual step rather than a fake assertion: stopping the API is not something
        // the test process can do from the device.
        throw XCTSkip("""
            #121 — needs the API stopped and restarted mid-run, which this process cannot do from \
            the device. Manual steps: open a chat, stop the API, send a message (expect .failed), \
            restart the API, then WITHOUT backgrounding the app confirm the message retries and \
            the chat reconnects.
            """)
    }

    // MARK: - Audio

    func testRecordingAndPlayingBackAVoiceMessageUsesTheRealMicrophone() throws {
        openFirstBookDiscussion()

        let record = app.buttons["recordButton"]
        guard record.waitForExistence(timeout: 5) else {
            throw XCTSkip("no record button — the account's tap-to-talk preference may differ")
        }

        record.tap()                              // tap-to-talk: starts recording
        Thread.sleep(forTimeInterval: 2)
        record.tap()                              // stops and sends

        // A voice bubble carries a duration only if real audio was captured and encoded — on a
        // device with no microphone access this is where it fails, which is the point.
        let voiceBubble = app.otherElements.matching(identifier: "voiceMessageBubble").firstMatch
        XCTAssertTrue(voiceBubble.waitForExistence(timeout: 30),
                      "no voice bubble appeared — check microphone permission and the upload path")
    }

    // MARK: - Helpers

    private func openFirstBookDiscussion() {
        let discussion = app.staticTexts["Discussion"].firstMatch
        XCTAssertTrue(discussion.waitForExistence(timeout: 15), "Library never showed a Discussion link")
        discussion.tap()
        XCTAssertTrue(app.textViews["messageTextField"].waitForExistence(timeout: 10), "Chat never loaded")
    }

    private func post(_ path: String, body: [String: Any], token: String?) throws -> [String: Any] {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try send(request, path: path)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func getArray(_ path: String, token: String) throws -> [[String: Any]] {
        var request = URLRequest(url: apiBaseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try send(request, path: path)
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    private func send(_ request: URLRequest, path: String) throws -> Data {
        var result: Result<Data, Error>?
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { result = .failure(error) }
            else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(NSError(domain: "OMBC", code: http.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "\(path) returned \(http.statusCode): \(String(data: data ?? Data(), encoding: .utf8) ?? "")"
                ]))
            } else { result = .success(data ?? Data()) }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result).get()
    }
}
