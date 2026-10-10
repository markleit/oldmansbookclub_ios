import Foundation

// #178 — the handful of endpoints the Share extension needs, over plain URLSession. Deliberately
// NOT the app's APIClient: that carries sign-out side effects, SignalR hand-offs and
// background-session plumbing that an extension must not run. Token refresh it does share, in
// spirit: SignInSession (Shared/SharedSignIn.swift, #204) refreshes the one-hour access token the
// same way and writes it back for the app. Same wire contract — snake_case JSON both ways, the
// same upload-then-post media flow as BookViewModel.sendMediaItem.
enum ShareError: LocalizedError {
    case signedOut
    case server(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Open Old Man's Book Club and sign in, then try again."
        case .server(let message): return message
        }
    }
}

struct ShareAPI {
    let baseURL: URL
    let signIn: SignInSession
    let deviceToken: String?

    /// nil when the app has no signed-in session this extension can read.
    static func current() -> ShareAPI? {
        let store = KeychainSignInStore()
        guard store.accessToken() != nil else { return nil }
        let defaults = SharedContainer.defaults
        let baseURL = resolveBaseURL(defaults)
        return ShareAPI(baseURL: baseURL,
                        signIn: SignInSession(baseURL: baseURL, store: store),
                        deviceToken: defaults?.string(forKey: SharedContainer.Key.deviceToken))
    }

    private static let productionURL = URL(string: "https://oldmansbookclub-api.azurewebsites.net")!

    private static func resolveBaseURL(_ defaults: UserDefaults?) -> URL {
        #if DEBUG
        // Published by the app's ServerEnvironment — so a .dev app pointed at a Dev Machine has
        // its extension post there too, with the token that server minted.
        if let s = defaults?.string(forKey: SharedContainer.Key.debugServerBaseURL), let url = URL(string: s) {
            return url
        }
        #endif
        return productionURL
    }

    // MARK: - Endpoints

    func books() async throws -> [ShareBook] {
        try Self.decoder.decode([ShareBook].self, from: try await send(request(path: "/books")))
    }

    func clubs() async throws -> [ShareClub] {
        try Self.decoder.decode([ShareClub].self, from: try await send(request(path: "/clubs")))
    }

    func sendText(_ text: String, bookId: UUID) async throws {
        try await postMessage(bookId: bookId, type: "Text", body: text, mediaUrl: nil)
    }

    func sendPhoto(jpeg: Data, book: ShareBook) async throws {
        struct UploadUrl: Decodable { let uploadUrl: String; let mediaUrl: String }
        var req = request(path: "/media/upload-url?clubId=\(book.clubId)&ext=jpg", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let urls = try Self.decoder.decode(UploadUrl.self, from: try await send(req))
        guard let uploadURL = URL(string: urls.uploadUrl) else { throw ShareError.server("Upload failed.") }

        var put = URLRequest(url: uploadURL)
        put.httpMethod = "PUT"
        put.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        put.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        let (_, response) = try await URLSession.shared.upload(for: put, from: jpeg)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ShareError.server("The photo didn't upload. Check your connection and try again.")
        }
        try await postMessage(bookId: book.id, type: "Photo", body: nil, mediaUrl: urls.mediaUrl)
    }

    // MARK: - Plumbing

    private func postMessage(bookId: UUID, type: String, body: String?, mediaUrl: String?) async throws {
        struct Payload: Encodable {
            let type: String; let body: String?; let mediaUrl: String?
            let clientId: UUID; let deviceId: String?
        }
        var req = request(path: "/books/\(bookId)/messages", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A fresh clientId per message: the server's (SenderId, ClientId) idempotency makes a
        // retried POST of the same message a no-op rather than a duplicate.
        req.httpBody = try Self.encoder.encode(Payload(type: type, body: body, mediaUrl: mediaUrl,
                                                       clientId: UUID(), deviceId: deviceToken))
        _ = try await send(req)
    }

    /// The bearer token is added by `send`, which owns refreshing it.
    private func request(path: String, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        req.httpMethod = method
        req.timeoutInterval = 30
        return req
    }

    /// #204 — the access token lasts an hour, so it's refreshed before sending when it's (nearly)
    /// expired, and once more if the server refuses it anyway. Only a refused REFRESH means
    /// "sign in in the app"; being unable to reach the server to refresh is a connection error.
    private func send(_ unsigned: URLRequest) async throws -> Data {
        var token = try await authorized { try await signIn.accessToken() }
        var (data, http) = try await perform(unsigned, token: token)
        if http.statusCode == 401 {
            token = try await authorized { try await signIn.tokenAfterRejection(of: token) }
            (data, http) = try await perform(unsigned, token: token)
            if http.statusCode == 401 { throw ShareError.signedOut }
        }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorBody: Decodable { let error: String }
            if let body = try? Self.decoder.decode(ErrorBody.self, from: data) { throw ShareError.server(body.error) }
            throw ShareError.server("Something went wrong (\(http.statusCode)). Try again.")
        }
        return data
    }

    private func perform(_ unsigned: URLRequest, token: String) async throws -> (Data, HTTPURLResponse) {
        var req = unsigned
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ShareError.server("No response from the server.") }
        return (data, http)
    }

    private func authorized(_ get: () async throws -> String) async throws -> String {
        do { return try await get() }
        catch SignInError.signedOut { throw ShareError.signedOut }
        catch { throw ShareError.server("Couldn't reach Old Man's Book Club. Check your connection and try again.") }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
}
