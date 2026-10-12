import XCTest
@testable import OldMansBookClub

/// #204 PR 7 (U10, W6) — a swiped-away app can't send until it's opened, so a notification 10
/// minutes after the oldest unsent message says so; never while the app is open.
final class SendReminderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ seconds: Double, _ status: SendItem.Status = .waiting) -> SendItem {
        SendItem(id: UUID(), bookId: UUID(), clubId: UUID(), kind: .text, sentAt: t0.addingTimeInterval(seconds),
                 body: "x", status: status)
    }

    func testW6ItsTenMinutesAfterTheOldestUnsentMessage() throws {
        let basis = try XCTUnwrap(SendReminder.basis(for: [item(120), item(0), item(60)]))
        XCTAssertEqual(SendReminder.plan(basis, after: 600, now: t0), ReminderPlan(fireAt: t0.addingTimeInterval(600), count: 3))
    }

    func testW6RefusedMessagesDontCountTheyWontSendAnyway() {
        XCTAssertNil(SendReminder.basis(for: [item(0, .refused)]))
        XCTAssertEqual(SendReminder.basis(for: [item(0, .refused), item(30)])?.count, 1)
    }

    func testW6NothingUnsentNoReminder() {
        XCTAssertNil(SendReminder.basis(for: []))
    }

    func testW6OneThatsOverdueComesAMinuteOutInstead() throws {
        // It fell due while the app was open (not shown then): leaving the app re-arms it.
        let basis = try XCTUnwrap(SendReminder.basis(for: [item(0)]))
        let now = t0.addingTimeInterval(3600)
        XCTAssertEqual(SendReminder.plan(basis, after: 600, now: now).fireAt, now.addingTimeInterval(60))
    }

    func testW6TheWordingAsAgreed() {
        XCTAssertEqual(SendReminder.text(count: 1),
                       "1 message waiting to send — it'll go automatically when you're online. If you closed the app, open it to finish.")
        XCTAssertEqual(SendReminder.text(count: 3),
                       "3 messages waiting to send — they'll go automatically when you're online. If you closed the app, open it to finish.")
    }

    func testW6ItIsntShownWhileTheAppIsOpenButOtherNotificationsAre() {
        XCTAssertEqual(SendReminder.foregroundOptions(for: SendReminder.identifier), [])
        XCTAssertNil(SendReminder.foregroundOptions(for: "a-push"), "pushes keep their own rules")
    }
}
