import Foundation

final class APIClient {
    static let shared = APIClient()

    private let baseURL = URL(string: "https://oldmansbookclub-api.azurewebsites.net")!

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

    // MARK: - Helpers

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
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
