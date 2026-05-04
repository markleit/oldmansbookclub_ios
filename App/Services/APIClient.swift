import Foundation

final class APIClient {
    static let shared = APIClient()

    #if targetEnvironment(simulator)
    private let baseURL = URL(string: "http://localhost:5235")!
    #else
    private let baseURL = URL(string: "https://oldmansbookclub-api.azurewebsites.net")!
    #endif

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoTZ = ISO8601DateFormatter()
        isoNoTZ.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoNoTZ.timeZone = TimeZone(identifier: "UTC")
        let iso2 = ISO8601DateFormatter()
        d.dateDecodingStrategy = .custom { decoder in
            let str = try decoder.singleValueContainer().decode(String.self)
            if let date = iso.date(from: str) { return date }
            if let date = isoNoTZ.date(from: str + "Z") { return date }
            if let date = iso2.date(from: str) { return date }
            if let date = iso2.date(from: str + "Z") { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Cannot decode date: \(str)")
        }
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Auth

    struct AppleAuthRequest: Encodable {
        let identityToken: String
        let displayName: String
    }

    struct AuthResponse: Decodable {
        let accessToken: String
        let user: UserResponse
    }

    struct UserResponse: Decodable {
        let id: UUID
        let displayName: String
    }

    func signInWithApple(identityToken: String, displayName: String) async throws -> AuthResponse {
        let body = AppleAuthRequest(identityToken: identityToken, displayName: displayName)
        return try await post(path: "/auth/apple", body: body, authenticated: false)
    }

    #if targetEnvironment(simulator)
    struct DevLoginRequest: Encodable { let displayName: String }

    func devLogin(displayName: String) async throws -> AuthResponse {
        let body = DevLoginRequest(displayName: displayName)
        return try await post(path: "/auth/dev-login", body: body, authenticated: false)
    }
    #endif

    // MARK: - Clubs

    func getMyClubs() async throws -> [Club] {
        try await get(path: "/clubs")
    }

    struct CreateClubRequest: Encodable {
        let name: String
        let description: String?
    }

    func createClub(name: String, description: String?) async throws -> Club {
        let body = CreateClubRequest(name: name, description: description)
        return try await post(path: "/clubs", body: body, authenticated: true)
    }

    // MARK: - Books

    func getMyBooks() async throws -> [Book] {
        try await get(path: "/books")
    }

    struct CreateBookRequest: Encodable {
        let clubId: UUID
        let title: String
        let author: String
        let coverUrl: String?
    }

    func createBook(clubId: UUID, title: String, author: String = "", coverUrl: String?) async throws -> Book {
        let body = CreateBookRequest(clubId: clubId, title: title, author: author, coverUrl: coverUrl)
        return try await post(path: "/books", body: body, authenticated: true)
    }

    struct BookSearchResult: Identifiable {
        let id = UUID()
        let title: String
        let author: String
        let coverUrl: String?
    }

    private static let googleBooksApiKey = "AIzaSyDTRMqMpatAG2Masvnhw5za5eFJOJi5Ej0"

    func searchBooks(title: String) async -> [BookSearchResult] {
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [
            .init(name: "q", value: "intitle:\(title)"),
            .init(name: "maxResults", value: "5"),
            .init(name: "printType", value: "books"),
            .init(name: "key", value: Self.googleBooksApiKey)
        ]
        guard let url = components.url else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let info = item["volumeInfo"] as? [String: Any],
                  let t = info["title"] as? String else { return nil }
            let author = (info["authors"] as? [String])?.first ?? ""
            let coverUrl = (info["imageLinks"] as? [String: Any])
                .flatMap { $0["thumbnail"] as? String }
                .map { $0.replacingOccurrences(of: "http://", with: "https://") }
            return BookSearchResult(title: t, author: author, coverUrl: coverUrl)
        }
    }

    struct SetStatusRequest: Encodable { let status: String }

    func setBookStatus(bookId: UUID, status: BookStatus) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/books/\(bookId)/status")!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(SetStatusRequest(status: status.rawValue))
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - Media

    struct UploadUrlResponse: Decodable {
        let uploadUrl: String
        let mediaUrl: String
    }

    func getUploadUrl(clubId: UUID) async throws -> UploadUrlResponse {
        try await post(path: "/media/upload-url?clubId=\(clubId)", body: EmptyRequest(), authenticated: true)
    }

    func uploadMedia(data: Data, to uploadUrl: URL, contentType: String) async throws {
        var request = URLRequest(url: uploadUrl)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        request.httpBody = data
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - Messages

    func getMessages(bookId: UUID, before: Date? = nil, limit: Int = 50) async throws -> [Message] {
        var path = "/books/\(bookId)/messages?limit=\(limit)"
        if let before {
            let iso = ISO8601DateFormatter()
            path += "&before=\(iso.string(from: before))"
        }
        return try await get(path: path)
    }

    private struct EmptyRequest: Encodable {}

    // MARK: - Notifications

    struct RegisterDeviceRequest: Encodable {
        let deviceToken: String
    }

    func registerDevice(token: String) async throws {
        let body = RegisterDeviceRequest(deviceToken: token)
        let _: EmptyResponse = try await post(path: "/notifications/register", body: body, authenticated: true)
    }

    func deleteBook(bookId: UUID) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/books/\(bookId)")!)
        request.httpMethod = "DELETE"
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private struct EmptyResponse: Decodable {}

    // MARK: - Helpers

    private func get<Response: Decodable>(path: String) async throws -> Response {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        request.httpMethod = "GET"
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try decoder.decode(Response.self, from: data)
    }

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        authenticated: Bool
    ) async throws -> Response {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated, let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try decoder.decode(Response.self, from: data)
    }
}
