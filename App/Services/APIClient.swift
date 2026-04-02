import Foundation

final class APIClient {
    static let shared = APIClient()

    private let baseURL = URL(string: "https://oldmansbookclub-api.azurewebsites.net")!

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        d.dateDecodingStrategy = .custom { decoder in
            let str = try decoder.singleValueContainer().decode(String.self)
            if let date = iso.date(from: str) { return date }
            // Fallback without fractional seconds
            let iso2 = ISO8601DateFormatter()
            if let date = iso2.date(from: str) { return date }
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
    }

    func createBook(clubId: UUID, title: String, author: String) async throws -> Book {
        let body = CreateBookRequest(clubId: clubId, title: title, author: author)
        return try await post(path: "/books", body: body, authenticated: true)
    }

    func finishBook(bookId: UUID) async throws {
        let _: EmptyResponse = try await post(path: "/books/\(bookId)/finish", body: EmptyRequest(), authenticated: true)
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

    private struct EmptyResponse: Decodable {}

    // MARK: - Helpers

    private func get<Response: Decodable>(path: String) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
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
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated, let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try decoder.decode(Response.self, from: data)
    }
}
