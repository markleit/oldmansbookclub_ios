import XCTest
@testable import OldMansBookClub

/// #204 PR 10 (U16, T10) — the share sheet queues its messages here and hands their uploads to
/// iOS; the app takes them into its outbox. What the extension writes must read back in the app,
/// and its request must be the app's own (the server dedups the two by client id).
final class ShareInboxTests: XCTestCase {
    private var inbox: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000.123)
    private let book = UUID(), club = UUID()

    override func setUp() {
        inbox = FileManager.default.temporaryDirectory.appendingPathComponent("ShareInboxTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: inbox)
    }

    private func entry(_ kind: ShareInbox.Entry.Kind, at offset: Double = 0, body: String? = nil) -> ShareInbox.Entry {
        .init(id: UUID(), bookId: book, clubId: club, kind: kind, sentAt: t0.addingTimeInterval(offset), body: body)
    }

    func testU16WhatTheShareSheetWritesReadsBackInTapOrderToTheMillisecond() throws {
        let photo = try ShareInbox.add(entry(.photo, at: 0.001), photo: Data([0xFF, 0xD8]), in: inbox)
        let caption = try ShareInbox.add(entry(.text, body: "look"), photo: nil, in: inbox)

        let read = ShareInbox.entries(in: inbox)

        XCTAssertEqual(read.map(\.id), [caption.id, photo.id], "the caption was tapped first, a millisecond earlier")
        XCTAssertEqual(read.first?.sentAt, caption.sentAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent(try XCTUnwrap(photo.fileName)).path))
    }

    func testU16AHalfWrittenMessageIsntTaken() throws {
        // The photo is written first, its record last: a crash between leaves no message.
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try Data([1]).write(to: inbox.appendingPathComponent("\(UUID().uuidString).jpg"))
        XCTAssertTrue(ShareInbox.entries(in: inbox).isEmpty)
    }

    func testU16AnUploadFromTheShareSheetIsTheAppsOwnRequest() throws {
        let base = URL(string: "https://api.test")!
        let shared = try ShareInbox.add(entry(.photo), photo: Data([0xFF, 0xD8]), in: inbox)
        let fromSheet = try ShareInbox.request(for: shared, in: inbox, baseURL: base, token: "tok", deviceId: "dev")

        let item = SendItem(id: shared.id, bookId: book, clubId: club, kind: .photo, sentAt: shared.sentAt,
                            fileName: shared.fileName, contentType: "image/jpeg")
        let fromApp = SendRequestBuilder.post(item, baseURL: base, token: "tok", deviceId: "dev",
                                              fileURL: fromSheet.bodyFile).request

        func query(_ r: URLRequest) -> Set<URLQueryItem> {
            Set(URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        }
        XCTAssertEqual(fromSheet.request.url?.path, fromApp.url?.path)
        XCTAssertEqual(query(fromSheet.request), query(fromApp))
        XCTAssertEqual(fromSheet.request.httpMethod, fromApp.httpMethod)
        XCTAssertEqual(fromSheet.request.value(forHTTPHeaderField: "Content-Type"), fromApp.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertEqual(fromSheet.request.value(forHTTPHeaderField: "Authorization"), fromApp.value(forHTTPHeaderField: "Authorization"))
    }

    func testU16ATextFromTheShareSheetIsTheAppsOwnRequest() throws {
        let base = URL(string: "https://api.test")!
        let shared = try ShareInbox.add(entry(.text, body: "a link and a thought"), photo: nil, in: inbox)
        let fromSheet = try ShareInbox.request(for: shared, in: inbox, baseURL: base, token: "tok", deviceId: "dev")
        let item = SendItem(id: shared.id, bookId: book, clubId: club, kind: .text, sentAt: shared.sentAt, body: shared.body)
        let fromApp = SendRequestBuilder.post(item, baseURL: base, token: "tok", deviceId: "dev", fileURL: nil)

        let sheetBody = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fromSheet.bodyFile)) as? NSDictionary)
        let appBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(fromApp.jsonBody)) as? NSDictionary)
        XCTAssertEqual(sheetBody, appBody)
        XCTAssertEqual(fromSheet.request.url, fromApp.request.url)
        XCTAssertEqual(fromSheet.request.httpMethod, fromApp.request.httpMethod)
    }

    func testU16TheAppReadsTheShareSheetsUploadResultAsItsOwn() {
        let shared = entry(.photo)
        XCTAssertEqual(SendTaskKey(taskDescription: ShareInbox.taskDescription(for: shared)),
                       SendTaskKey(itemId: shared.id, attempt: 1, step: .post))
    }
}
