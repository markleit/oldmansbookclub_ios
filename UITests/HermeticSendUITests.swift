import XCTest

/// #204 — fire-and-forget sending, driven through the real app against the hermetic stub (CI half
/// 3). Each test is one scenario from the spec: send, then walk away / lose the server / get refused
/// — and the message still arrives (or says clearly why it can't) with nobody tapping Retry.
///
/// The stub stands in for the server: `/_stub/sent` is what actually landed (deduped by client id,
/// like the real server), `/_stub/script` makes the next requests fail in a chosen way, and
/// `/_stub/down` makes the server unreachable. DEBUG launch arguments shorten the send timings so
/// the real schedule runs in seconds (#204 T2).
final class HermeticSendUITests: HermeticTestCase {

    /// Spinner → "waiting" after 3 s; retries 10× faster than in the app (0.1, 0.2, 0.4… s).
    private let fastTimings = ["-sendWaitingAfter", "3", "-sendTimingScale", "0.1", "-sendDirectNudge", "1"]

    // MARK: - Helpers

    private func send(_ text: String) {
        let field = app.textViews["messageTextField"]
        field.tap()
        field.typeText(text)
        let button = app.buttons["sendButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "sendButton never appeared after typing")
        button.tap()
    }

    /// Everything that has landed on the stub, waiting up to `timeout` for at least `count`.
    @discardableResult
    private func waitForSent(_ count: Int, timeout: TimeInterval) throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(timeout)
        var sent: [[String: Any]] = []
        repeat {
            sent = try sentMessages()
            if sent.count >= count { return sent }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return sent
    }

    /// What the stub saw — attached to a failure so a flaky run explains itself.
    private func trail() -> String {
        // One line: the CI log keeps only the first line of a failure message.
        ((try? requestedPaths()) ?? []).suffix(25).joined(separator: " | ")
    }

    private func script(_ route: String, _ responses: [[String: Any]]) throws {
        try controlRequest(path: "/_stub/script", method: "POST", jsonBody: ["route": route, "responses": responses])
    }

    private func setServerDown(_ down: Bool) throws {
        try controlRequest(path: "/_stub/down", method: "POST", jsonBody: ["down": down])
    }

    private func requests(matching fragment: String) throws -> Int {
        try requestedPaths().filter { $0.contains(fragment) }.count
    }

    private func indicator(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func goBack() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Discussion"].firstMatch.waitForExistence(timeout: 10), "never got back to the Library")
    }

    private func pickPhotos(_ count: Int) {
        app.buttons["attachmentMenuButton"].tap()
        let photos = app.buttons["Photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 5), "+ menu has no Photos item")
        photos.tap()
        let thumbs = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'"))
        XCTAssertTrue(thumbs.firstMatch.waitForExistence(timeout: 20), "photo picker never showed the library")
        XCTAssertGreaterThanOrEqual(thumbs.count, count, "simulator library needs at least \(count) sample photos")
        for i in 0..<count { thumbs.element(boundBy: i).tap() }
        // The picker's confirm (✓): identifier "Add", label "Done" — not the app's own "Add" button.
        app.buttons.matching(NSPredicate(format: "identifier == 'Add' AND label != 'Add'")).firstMatch.tap()
        let pending = app.descendants(matching: .any).matching(identifier: "pendingPhoto")
        XCTAssertTrue(pending.element(boundBy: count - 1).waitForExistence(timeout: 20), "picked photos didn't reach the composer")
    }

    // MARK: - H1: as fast as before

    func testATextReachesTheServerWithinTwoSecondsOfTappingSend() throws {
        launch()
        openCurrentBook()

        send("quick one")
        let tapped = Date()
        let sent = try waitForSent(1, timeout: 10)

        XCTAssertEqual(sent.first?["body"] as? String, "quick one")
        XCTAssertLessThan(Date().timeIntervalSince(tapped), 2.5, "a text must go at once while the app is open")
    }

    func testS3APhotoReachesTheServerWithinSecondsWithTheAppOpen() throws {
        // Voice/photo go via iOS first, and directly too if iOS hasn't delivered within 3 s — so
        // with the app open a photo never waits on iOS's schedule (#207 saw 86 s).
        try setMessages([])
        launch()
        openCurrentBook()

        pickPhotos(1)
        app.buttons["sendButton"].tap()
        let tapped = Date()
        let sent = try waitForSent(1, timeout: 20)

        XCTAssertEqual(sent.first?["type"] as? String, "Photo")
        XCTAssertLessThan(Date().timeIntervalSince(tapped), 5, "a photo must go within seconds while the app is open")
    }

    // MARK: - H2–H5: walking away

    func testATextSentThenLeftImmediatelyStillArrives() throws {
        // #204 A2 — leaving the chat used to strand a failed text until that chat was reopened.
        try script("POST /books/*/messages", [["delay": 2], ["delay": 2]])
        launch()
        openCurrentBook()

        send("said and gone")
        goBack()

        XCTAssertEqual(try waitForSent(1, timeout: 15).first?["body"] as? String, "said and gone")
        openCurrentBook()
        XCTAssertTrue(app.staticTexts["said and gone"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForDisappearance(indicator("sendingIndicator"), timeout: 10), "the bubble never showed as sent")
    }

    func testAPhotoSentThenLeftImmediatelyStillArrives() throws {
        // A2 for media: 2.1 never posted a photo whose upload finished after you left the chat.
        try setMessages([])
        try script("POST /books/*/messages", [["delay": 3], ["delay": 3]])
        launch()
        openCurrentBook()

        pickPhotos(1)
        app.buttons["sendButton"].tap()
        goBack()

        let sent = try waitForSent(1, timeout: 20)
        XCTAssertEqual(sent.first?["type"] as? String, "Photo")
        XCTAssertEqual(sent.first?["via"] as? String, "file", "one request: the photo itself (#204 PR 1)")
    }

    func testSendsInTwoChatsBothArriveWhileYouSitInTheLibrary() throws {
        // A8 — each chat used to send only while it was open.
        try script("POST /books/*/messages", [["delay": 2], ["delay": 2], ["delay": 2], ["delay": 2]])
        launch()
        openCurrentBook()
        send("in the current read")
        goBack()
        let future = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Seed: Future Read'")).firstMatch
        XCTAssertTrue(future.waitForExistence(timeout: 5), "the future read isn't in the Library")
        future.tap()
        XCTAssertTrue(app.textViews["messageTextField"].waitForExistence(timeout: 10), "future read's chat never loaded")
        send("in the future read")
        goBack()

        let sent = try waitForSent(2, timeout: 20)
        XCTAssertEqual(Set(sent.compactMap { $0["body"] as? String }), ["in the current read", "in the future read"])
        XCTAssertEqual(Set(sent.compactMap { $0["book_id"] as? String }).count, 2)
    }

    func testATextSentThenBackgroundedStillArrives() throws {
        // A3 — iOS carries it once handed over; the app needn't be on screen.
        try script("POST /books/*/messages", [["delay": 3], ["delay": 3]])
        launch()
        openCurrentBook()

        send("then home")
        XCUIDevice.shared.press(.home)

        XCTAssertEqual(try waitForSent(1, timeout: 30).first?["body"] as? String, "then home")
        app.activate()
    }

    // MARK: - H6: the app was killed with messages queued

    func testMessagesQueuedWhenTheAppWasKilledGoOnRelaunchWithoutOpeningTheChat() throws {
        // A5/A6 — on disk before anything is sent; the engine sends from any screen at launch.
        launch(extraArguments: fastTimings)
        openCurrentBook()
        try setServerDown(true)
        for text in ["one", "two", "three"] { send(text) }
        XCTAssertTrue(indicator("waitingSendIndicator").waitForExistence(timeout: 15), "never showed waiting while the server was down")
        app.terminate()

        try setServerDown(false)
        launch(freshState: false, extraArguments: fastTimings)   // lands on the Library; the chat is never opened

        let sent = try waitForSent(3, timeout: 30)
        XCTAssertEqual(Set(sent.compactMap { $0["body"] as? String }), ["one", "two", "three"])
    }

    // MARK: - H7–H10: server trouble, retried on the shared clock

    func testWhenTheServerIsDownItShowsWaitingThenSendsByItselfWhenItsBack() throws {
        // B4 / #121 — nothing used to retry while the network was up but the server wasn't.
        launch(extraArguments: fastTimings)
        openCurrentBook()
        try setServerDown(true)

        send("while it's down")
        XCTAssertTrue(indicator("waitingSendIndicator").waitForExistence(timeout: 15), "a passing failure should become a quiet clock, not red")
        XCTAssertFalse(indicator("failedSendIndicator").exists, "never red for a passing failure")

        // B5 (PR 7): the Library says so too.
        goBack()
        let unsent = indicator("unsentCount")
        XCTAssertTrue(unsent.waitForExistence(timeout: 5), "the book's row should say it has an unsent message")
        // The row is one button, so it reads as one label: "<title>, <author>, 1 unsent, Discussion".
        XCTAssertTrue(unsent.label.contains("1 unsent"), "the row says \(unsent.label)")

        try setServerDown(false)
        XCTAssertEqual(try waitForSent(1, timeout: 30).first?["body"] as? String, "while it's down")
        XCTAssertTrue(waitForDisappearance(unsent, timeout: 15), "the Library's count clears once it's sent")
    }

    func testServerErrorsAreRetriedAutomatically() throws {
        try script("POST /books/*/messages", Array(repeating: ["status": 503], count: 4))
        launch(extraArguments: fastTimings)
        openCurrentBook()

        send("persistent")

        XCTAssertEqual(try waitForSent(1, timeout: 30).first?["body"] as? String, "persistent")
        XCTAssertGreaterThanOrEqual(try requests(matching: "/messages"), 3, "it took retries to get through")
    }

    func testAnExpiredSignInIsRefreshedOnceAndTheMessageSent() throws {
        // B8 — a refused token is refreshed and the send repeated at once.
        try script("POST /books/*/messages", [["status": 401], ["status": 401]])
        launch(extraArguments: fastTimings)
        openCurrentBook()
        let refreshesBefore = try requests(matching: "/auth/refresh")

        send("after a refresh")

        XCTAssertEqual(try waitForSent(1, timeout: 20).first?["body"] as? String, "after a refresh",
                       "Stub saw: \(trail())")
        XCTAssertEqual(try requests(matching: "/auth/refresh") - refreshesBefore, 1, "one refresh, not one per copy")
    }

    func testRateLimitedWaitsForRetryAfterThenSends() throws {
        // E1 — 429 is not a refusal: wait as long as the server says, then send.
        try script("POST /books/*/messages", [["status": 429, "retry_after": 3], ["status": 429, "retry_after": 3]])
        launch(extraArguments: fastTimings)
        openCurrentBook()

        send("slow down")
        let tapped = Date()

        XCTAssertEqual(try waitForSent(1, timeout: 20).first?["body"] as? String, "slow down")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(tapped), 3, "it waited for Retry-After")
        XCTAssertFalse(indicator("failedSendIndicator").exists)
    }

    // MARK: - H11–H12: what the sender can do

    func testARefusedMessageShowsTheReasonAndCanBeDeleted() throws {
        // E2 — a permanent refusal is red with the server's reason, never retried, never silent.
        let reason = "Not a member of this club."
        try script("POST /books/*/messages", [["status": 400, "body": ["error": reason]], ["status": 400, "body": ["error": reason]]])
        launch(extraArguments: fastTimings)
        openCurrentBook()

        send("not allowed")
        let refused = app.buttons.matching(identifier: "failedSendIndicator").firstMatch
        XCTAssertTrue(refused.waitForExistence(timeout: 10), "a refusal should show red")
        let attempts = try requests(matching: "/messages")
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(try requests(matching: "/messages"), attempts, "a refusal is never retried")

        // B5 (PR 7): the Library row turns red.
        goBack()
        XCTAssertTrue(indicator("unsentRefused").waitForExistence(timeout: 5), "the book's row should show it in red")
        openCurrentBook()
        XCTAssertTrue(refused.waitForExistence(timeout: 10))

        refused.tap()
        // A menu's text row may be exposed as a button or as text — match the label either way.
        let reasonRow = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", reason)).firstMatch
        XCTAssertTrue(reasonRow.waitForExistence(timeout: 5), "the reason isn't shown")
        XCTAssertTrue(app.buttons["Copy"].exists, "a refused text offers Copy, so what was written isn't lost (B4)")
        app.buttons["Delete"].tap()
        XCTAssertTrue(waitForDisappearance(app.staticTexts["not allowed"], timeout: 5), "Delete didn't remove it")
        XCTAssertTrue(try sentMessages().isEmpty, "a refused message reached the server. Stub saw: \(trail())")
    }

    func testSendNowTriesImmediatelyInsteadOfWaitingForTheNextRetry() throws {
        // F1 — retries 100× slower than the app's, so only Send now can explain a quick arrival.
        try script("POST /books/*/messages", [["status": 503], ["status": 503]])
        launch(extraArguments: ["-sendWaitingAfter", "1", "-sendTimingScale", "100"])
        openCurrentBook()

        send("now please")
        let waiting = app.buttons.matching(identifier: "waitingSendIndicator").firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 15))
        waiting.tap()
        // B3: the menu says it'll go by itself, and offers Send now and Delete.
        let note = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Will send automatically'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5), "the waiting menu doesn't say it'll send by itself")
        XCTAssertTrue(app.buttons["Delete"].exists, "the waiting menu has no Delete")
        app.buttons["Send now"].tap()

        XCTAssertEqual(try waitForSent(1, timeout: 8).first?["body"] as? String, "now please",
                       "Send now didn't deliver it. Stub saw: \(trail())")
    }

    func testB3AWaitingMessageDeletedFromItsMenuNeverArrives() throws {
        launch(extraArguments: fastTimings)
        openCurrentBook()
        try setServerDown(true)

        send("changed my mind")
        let waiting = app.buttons.matching(identifier: "waitingSendIndicator").firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 15))
        waiting.tap()
        app.buttons["Delete"].tap()
        XCTAssertTrue(waitForDisappearance(app.staticTexts["changed my mind"], timeout: 5), "Delete didn't remove it")

        // A new send resets the retry clock and sends everything still queued at once — so if the
        // delete had only hidden the message, it would go out alongside this one. (Waiting a few
        // seconds instead raced the backoff: the check passed when the next retry was later.)
        try setServerDown(false)
        send("still here")
        XCTAssertEqual(try waitForSent(1, timeout: 15).first?["body"] as? String, "still here")
        Thread.sleep(forTimeInterval: 2)   // anything sent with it has landed by now
        XCTAssertEqual(try sentMessages().compactMap { $0["body"] as? String }, ["still here"],
                       "a deleted message was sent anyway. Stub saw: \(trail())")
    }

    // MARK: - O3: the chat is in tap-time order on the sender's phone too (PR 6)

    func testO3APhotoTappedBeforeATextStaysAboveItWhenTheTextLandsFirst() throws {
        // The 2026-10-11 report (a video, then a voice message): the slower upload landed second and
        // jumped below the quicker message tapped after it. It belongs where it was tapped.
        try setMessages([])
        // The photo's upload only (the text's copies share the route, and can reach the stub first).
        try script("POST /books/*/messages", [["delay": 5, "content_type": "image/jpeg"]])
        launch(extraArguments: ["-sendDirectNudge", "30"])     // no second, direct copy of it meanwhile
        openCurrentBook()

        pickPhotos(1)
        app.buttons["sendButton"].tap()
        send("tapped after the photo")

        XCTAssertEqual(try waitForSent(2, timeout: 30).count, 2, "Stub saw: \(trail())")
        XCTAssertTrue(waitForDisappearance(indicator("sendingIndicator"), timeout: 20), "both should be confirmed")
        let photo = app.buttons.matching(identifier: "photoMessage").firstMatch
        let text = app.staticTexts["tapped after the photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5) && text.exists)
        XCTAssertLessThan(photo.frame.minY, text.frame.minY, "the photo was tapped first, so it stays above the text")
    }

    // MARK: - H14: video (PR 5)

    func testH14AVideoLeavesTheComposerFreeAtOnceAndArrivesWhenReady() throws {
        // Compressed after it's queued: tapping Send frees the chat straight away (it used to
        // show a spinner for the whole compression), then the video goes on its own.
        try setMessages([])
        launch()
        openCurrentBook()

        app.buttons["attachmentMenuButton"].tap()
        let videoItem = app.buttons["Video"]
        XCTAssertTrue(videoItem.waitForExistence(timeout: 5), "+ menu has no Video item")
        videoItem.tap()
        // The sample clip (scripts/fixtures/sample-video.mp4, added by regression.sh).
        let clip = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Video'")).firstMatch
        XCTAssertTrue(clip.waitForExistence(timeout: 20), "the picker shows no video — was the sample clip added?")
        clip.tap()
        let picked = app.descendants(matching: .any).matching(identifier: "pendingVideo").firstMatch
        if !picked.waitForExistence(timeout: 10) {
            // Some iOS versions want the picker's confirm (✓) even for one item.
            app.buttons.matching(NSPredicate(format: "identifier == 'Add' AND label != 'Add'")).firstMatch.tap()
        }
        XCTAssertTrue(picked.waitForExistence(timeout: 20), "the picked video didn't reach the composer")

        app.buttons["sendButton"].tap()
        // The mic is back (an image with a press gesture in hold-to-talk mode, so any element).
        XCTAssertTrue(indicator("micButton").waitForExistence(timeout: 2),
                      "the composer should be free at once — the video is compressed after it's queued")

        let sent = try waitForSent(1, timeout: 60)
        XCTAssertEqual(sent.first?["type"] as? String, "Video", "Stub saw: \(trail())")
    }

    // MARK: - H13: a batch keeps the order it was sent in

    func testPhotosAndTheirCaptionKeepTheOrderTheyWereSentIn() throws {
        // #201 + #204 (1b) — sent in parallel, so they can ARRIVE in any order; each carries its
        // tap time, which is what orders the chat. Replaces the old "post in order" and "start
        // every upload together" tests: there's no upload-link step and no line to wait in.
        try setMessages([])
        launch()
        openCurrentBook()

        pickPhotos(3)
        let field = app.textViews["messageTextField"]
        field.tap()
        field.typeText("a caption")
        app.buttons["sendButton"].tap()

        let sent = try waitForSent(4, timeout: 45)
        XCTAssertEqual(sent.count, 4, "the caption and three photos, each once: \(sent) — Stub saw: \(trail())")
        let byTapTime = sent.sorted { ($0["sent_at"] as? String ?? "") < ($1["sent_at"] as? String ?? "") }
        XCTAssertEqual(byTapTime.map { $0["type"] as? String }, ["Text", "Photo", "Photo", "Photo"])
        XCTAssertEqual(byTapTime.first?["body"] as? String, "a caption")
        XCTAssertEqual(Set(sent.compactMap { $0["sent_at"] as? String }).count, 4, "every tap time is distinct")

        let bubbles = app.buttons.matching(identifier: "photoMessage")
        let settled = NSPredicate(format: "count == 3")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: settled, object: bubbles)], timeout: 15),
                       .completed, "expected 3 photo bubbles, found \(bubbles.count)")
    }
}
