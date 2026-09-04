import Foundation
import Network

/// A minimal HTTP server run by the UI-test process, so UI flows can be exercised with no backend.
///
/// This needs NO production code. `ServerEnvironment` already resolves its host at runtime from
/// the `debugServerBaseURL` default (#120), and a launch argument of the form `-key value`
/// populates UserDefaults — so launching the app with `-debugServerBaseURL http://127.0.0.1:PORT`
/// points it here. Nothing stub-shaped ships in the app binary, and there is no injection seam to
/// keep in sync with a growing API surface.
///
/// It answers the shape of a request, not a script of expected calls: an unrecognised GET returns
/// `[]` and an unrecognised POST returns `{}`. A stub that had to enumerate every endpoint would
/// break every time the app started calling one more thing, which is the failure mode that makes
/// people delete stubs.
///
/// SignalR is deliberately unsupported — the app's connection attempt simply fails, exactly as it
/// does with no network, and the chat still renders from REST. These tests are for what the client
/// draws, not for realtime delivery, which lanes B and C cover against a real server.
final class StubAPIServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ombc.stub-api")
    private let state: StubState

    /// The URL to launch the app against.
    var baseURL: String { "http://127.0.0.1:\(listener.port?.rawValue ?? 0)" }

    /// Every path the app asked for, in order — so a test can assert the app actually called the
    /// server rather than rendering from a stale cache.
    private(set) var requestedPaths: [String] = []
    private let lock = NSLock()

    init(state: StubState = StubState()) throws {
        self.state = state
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)

        // The port is assigned asynchronously; the caller needs it in `baseURL` immediately.
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            guard let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel() } else { self.receive(on: connection, buffer: accumulated) }
                return
            }

            let head = String(decoding: accumulated[..<headerEnd.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.first?.components(separatedBy: " ") ?? []
            let method = requestLine.first ?? "GET"
            let path = requestLine.count > 1 ? requestLine[1] : "/"

            // Wait for the whole body before answering, or a send would be answered before its
            // JSON arrived and the stub would echo the wrong thing.
            let declaredLength = lines
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
            let body = accumulated[headerEnd.upperBound...]
            if body.count < declaredLength {
                self.receive(on: connection, buffer: accumulated)
                return
            }

            self.lock.lock(); self.requestedPaths.append("\(method) \(path)"); self.lock.unlock()

            let response = self.state.respond(method: method, path: path, body: Data(body))
            self.send(response, on: connection)
        }
    }

    private func send(_ json: String, on connection: NWConnection) {
        let body = Data(json.utf8)
        let header = """
            HTTP/1.1 200 OK\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r\n
            """
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// The canned world the stub serves. A test mutates this before launching the app.
final class StubState {
    let clubId = "22222222-2222-2222-2222-222222222222"
    let userId = "33333333-3333-3333-3333-333333333333"
    let currentBookId = "66666666-6666-6666-6666-666666666666"
    let futureBookId = "77777777-7777-7777-7777-777777777777"

    /// Messages served for the current book, newest first. Tests append to this.
    var messages: [String] = []

    /// When true, every send is refused with a 400-shaped body — the app should mark the bubble
    /// failed and keep it, rather than dropping it silently.
    var refuseSends = false

    private var user: String {
        """
        {"id":"\(userId)","display_name":"Mark","nickname":null,"avatar_url":null,
         "is_admin":true,"is_club_admin":true,"preferences":{"tap_to_talk":false}}
        """
    }

    private func book(id: String, title: String, status: String, order: Int) -> String {
        """
        {"id":"\(id)","club_id":"\(clubId)","title":"\(title)","author":"Test Author",
         "cover_blob_url":null,"added_at":"2026-09-01T00:00:00.000Z","finished_at":null,
         "status":"\(status)","description":null,"published_year":null,"page_count":null,
         "unread_count":0,"series_name":null,"series_order":\(order)}
        """
    }

    private func message(_ body: String, index: Int) -> String {
        """
        {"id":"\(String(format: "88888888-8888-8888-8888-%012d", index))","club_id":"\(clubId)",
         "sender_id":"99999999-9999-9999-9999-999999999999","sender_name":"Dixie",
         "sender_avatar_url":null,"type":"Text","body":"\(body)","media_url":null,
         "duration_seconds":null,"sent_at":"2026-09-01T12:00:0\(index % 10).000Z",
         "is_deleted":false,"is_forwarded":false,"client_id":null,"parent_message_id":null,
         "parent_sender_name":null,"parent_preview":null,"parent_sent_at":null,
         "transcript":null,"reactions":null}
        """
    }

    func respond(method: String, path: String, body: Data) -> String {
        let route = path.components(separatedBy: "?").first ?? path

        switch (method, route) {
        case ("POST", "/auth/dev-login"), ("POST", "/auth/refresh"):
            return """
                {"access_token":"stub-access-token","refresh_token":"stub-refresh-token","user":\(user)}
                """

        case ("GET", "/users/me"):
            return user

        case ("GET", "/clubs"):
            return """
                [{"id":"\(clubId)","name":"Old Man's Book Club","description":null,
                  "cover_blob_url":null,"is_club_admin":true}]
                """

        case ("GET", "/books"):
            return """
                [\(book(id: currentBookId, title: "Seed: Current Read", status: "current", order: 0)),
                 \(book(id: futureBookId, title: "Seed: Future Read", status: "future", order: 0))]
                """

        case ("GET", "/books/\(currentBookId)/messages"):
            return "[" + messages.enumerated().map { message($1, index: $0) }.joined(separator: ",") + "]"

        case ("POST", "/books/\(currentBookId)/messages"):
            if refuseSends {
                // The stub always answers 200, so a refusal is expressed the way the app's own
                // decoder sees a malformed success — enough to drive the failure branch without
                // teaching the stub about status codes.
                return #"{"error":"stub refused this send"}"#
            }
            return echoSent(body)

        default:
            return method == "GET" ? "[]" : "{}"
        }
    }

    /// Echoes a send back as a confirmed message, preserving the client_id — which is what the
    /// reconciler matches on, so without it the app would show two bubbles.
    private func echoSent(_ body: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let text = json["body"] as? String ?? ""
        let clientId = json["client_id"] as? String
        return """
            {"id":"\(UUID().uuidString)","club_id":"\(clubId)","sender_id":"\(userId)",
             "sender_name":"Mark","sender_avatar_url":null,"type":"Text","body":"\(text)",
             "media_url":null,"duration_seconds":null,"sent_at":"2026-09-01T12:30:00.000Z",
             "is_deleted":false,"is_forwarded":false,
             "client_id":\(clientId.map { "\"\($0)\"" } ?? "null"),
             "parent_message_id":null,"parent_sender_name":null,"parent_preview":null,
             "parent_sent_at":null,"transcript":null,"reactions":null}
            """
    }
}
