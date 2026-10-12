import Foundation

/// #204 PR 10 — messages the Share extension has queued, waiting to join the app's outbox.
///
/// The share sheet closes at once. For each message the extension writes its photo (if any) and a
/// small record here, in the App Group, and hands the upload to iOS's background transfer, which
/// carries it after the sheet and the extension are gone — the phone can lock. The app takes these
/// into its outbox when it next runs (launch, foreground, or iOS waking it with the result), and
/// from then on each is an ordinary unsent message: waited for if iOS has it, retried if not.
/// The record is written after its file, so a half-written message is never taken.
enum ShareInbox {
    /// Each share gets its own background session: one process at a time can hold a session, and
    /// the app (suspended in the background) mustn't be holding the one the extension needs. The app
    /// joins a share's session only when iOS wakes it with that session's results.
    static let sessionPrefix = "ombc.share-send."

    static func newSessionIdentifier() -> String { sessionPrefix + UUID().uuidString }

    static func isShareSession(_ identifier: String) -> Bool { identifier.hasPrefix(sessionPrefix) }

    struct Entry: Codable, Equatable {
        enum Kind: String, Codable { case text, photo }
        /// The client id — the server dedups a retry from the app by it.
        let id: UUID
        let bookId: UUID
        let clubId: UUID
        let kind: Kind
        /// Tap time: when Send was tapped in the share sheet.
        let sentAt: Date
        var body: String?
        /// The photo, in the inbox directory.
        var fileName: String?
        /// The extension handed the upload to iOS in this session: the app waits for its result
        /// (and sends directly too while it's open) rather than start a second background upload.
        var sessionIdentifier: String?
        var handedToIOS: Bool { sessionIdentifier != nil }
    }

    static func defaultDirectory() -> URL? {
        SharedContainer.appGroupId
            .flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            .map { $0.appendingPathComponent("Outbox/inbox", isDirectory: true) }
    }

    /// Writes a message for the app to take: its photo first, then the record.
    @discardableResult
    static func add(_ entry: Entry, photo: Data?, in directory: URL) throws -> Entry {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var entry = entry
        if let photo {
            let name = entry.id.uuidString + ".jpg"
            try photo.write(to: directory.appendingPathComponent(name), options: .atomic)
            entry.fileName = name
        }
        try save(entry, in: directory)
        return entry
    }

    static func save(_ entry: Entry, in directory: URL) throws {
        try encoder.encode(entry).write(to: directory.appendingPathComponent(entry.id.uuidString + ".json"),
                                       options: .atomic)
    }

    /// Everything waiting, oldest tap first.
    static func entries(in directory: URL) -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasSuffix(".body.json") }
            .compactMap { try? decoder.decode(Entry.self, from: Data(contentsOf: directory.appendingPathComponent($0))) }
            .sorted { $0.sentAt < $1.sentAt }
    }

    /// The app has the message: its record goes. Its files stay until it's sent — iOS may still be
    /// uploading from them (`removeFiles`).
    static func remove(_ entry: Entry, in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.id.uuidString + ".json"))
    }

    /// A message is sent (or deleted): its photo and request body go too.
    static func removeFiles(for id: UUID, in directory: URL) {
        for name in [id.uuidString + ".jpg", id.uuidString + ".body.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// How the app's engine reads the result: SendTaskKey for attempt 1 of the post.
    static func taskDescription(for entry: Entry) -> String { "ombc2|\(entry.id.uuidString)|1|post" }

    /// The request that creates the message, and the file to upload as its body — the same request
    /// the app builds (SendRequestBuilder; ShareInboxTests keeps the two identical).
    static func request(for entry: Entry, in directory: URL, baseURL: URL, token: String,
                        deviceId: String?) throws -> (request: URLRequest, bodyFile: URL) {
        let path = baseURL.appendingPathComponent("books/\(entry.bookId.uuidString.lowercased())/messages")
        let sentAt = sentAtFormatter.string(from: entry.sentAt)
        var request: URLRequest
        let bodyFile: URL
        if entry.kind == .photo, let name = entry.fileName {
            var components = URLComponents(url: path, resolvingAgainstBaseURL: false)!
            var query = [URLQueryItem(name: "client_id", value: entry.id.uuidString.lowercased()),
                         URLQueryItem(name: "sent_at", value: sentAt)]
            if let deviceId { query.append(URLQueryItem(name: "device_id", value: deviceId)) }
            components.queryItems = query
            request = URLRequest(url: components.url!)
            request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            bodyFile = directory.appendingPathComponent(name)
        } else {
            var json: [String: Any] = ["type": "Text", "client_id": entry.id.uuidString.lowercased(), "sent_at": sentAt]
            if let body = entry.body { json["body"] = body }
            if let deviceId { json["device_id"] = deviceId }
            bodyFile = directory.appendingPathComponent(entry.id.uuidString + ".body.json")
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: bodyFile, options: .atomic)
            request = URLRequest(url: path)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return (request, bodyFile)
    }

    static let sentAtFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // Default date coding (seconds as a Double): keeps the milliseconds that order a shared
    // caption and its photos — ISO 8601 here would drop them.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
