import Foundation

enum APIError: LocalizedError {
    case pendingApproval(clubName: String)
    case requestDeclined(clubName: String)
    case needsClubSetup
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .pendingApproval(let name): return "Your request to join \(name) is pending admin approval."
        case .requestDeclined(let name): return "Your request to join \(name) was declined."
        case .needsClubSetup: return "Please set up your club to continue."
        case .serverError(let code): return "Server error (\(code))."
        }
    }
}

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
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    private let uploadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300  // 5 min ceiling for large video
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    var onUnauthorized: (() -> Void)?

    private init() {}

    // MARK: - Auth

    struct AppleAuthRequest: Encodable {
        let identityToken: String
        let displayName: String
        let email: String?
        let clubName: String?
        let joinClubId: UUID?
        let authorizationCode: String?
    }

    struct SetupRequiredResponse: Decodable {
        let status: String
        let clubName: String?
    }

    struct PublicClub: Decodable, Identifiable {
        let id: UUID
        let name: String
        let memberCount: Int
    }

    struct JoinRequest: Decodable, Identifiable {
        let id: UUID
        let userId: UUID
        let displayName: String
        let email: String?
        let clubId: UUID
        let clubName: String
        let createdAt: Date
    }

    struct AuthResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let user: UserResponse
    }

    struct RefreshTokenRequest: Encodable { let refreshToken: String }

    // Distinguishes a definitive refresh-token rejection (the token is dead → sign out)
    // from a transient failure (network down, server 5xx, timeout → keep the session and
    // retry later). Conflating the two is what signs users out after an idle period.
    enum RefreshError: Error { case rejected, transient }

    func refresh(refreshToken: String) async throws -> AuthResponse {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/auth/refresh")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? encoder.encode(RefreshTokenRequest(refreshToken: refreshToken))
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RefreshError.transient   // network blip — not the token's fault
        }
        guard let http = response as? HTTPURLResponse else { throw RefreshError.transient }
        if http.statusCode == 401 || http.statusCode == 403 { throw RefreshError.rejected }
        guard (200..<300).contains(http.statusCode) else { throw RefreshError.transient }
        do {
            return try decoder.decode(AuthResponse.self, from: data)
        } catch {
            throw RefreshError.transient
        }
    }

    func logout(refreshToken: String) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/auth/logout")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(RefreshTokenRequest(refreshToken: refreshToken))
        _ = try? await session.data(for: request)
    }

    struct UserPreferences: Decodable {
        let tapToTalk: Bool
    }

    struct UserResponse: Decodable {
        let id: UUID
        let displayName: String
        let nickname: String?
        let avatarUrl: String?
        let isAdmin: Bool
        let isClubAdmin: Bool
        let preferences: UserPreferences
    }

    func signInWithApple(identityToken: String, displayName: String, email: String?, clubName: String? = nil, joinClubId: UUID? = nil, authorizationCode: String? = nil) async throws -> AuthResponse {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/auth/apple")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(AppleAuthRequest(identityToken: identityToken, displayName: displayName, email: email, clubName: clubName, joinClubId: joinClubId, authorizationCode: authorizationCode))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 202 {
            let setup = try? decoder.decode(SetupRequiredResponse.self, from: data)
            switch setup?.status {
            case "pending_approval":
                throw APIError.pendingApproval(clubName: setup?.clubName ?? "the club")
            case "request_declined":
                throw APIError.requestDeclined(clubName: setup?.clubName ?? "the club")
            default:
                throw APIError.needsClubSetup
            }
        }
        if http.statusCode == 401 { throw URLError(.userAuthenticationRequired) }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try decoder.decode(AuthResponse.self, from: data)
    }

    func getPublicClubs() async throws -> [PublicClub] {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/clubs/public")!)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try decoder.decode([PublicClub].self, from: data)
    }

    func getJoinRequests() async throws -> [JoinRequest] {
        try await get(path: "/admin/join-requests")
    }

    func approveJoinRequest(id: UUID) async throws {
        try await postEmpty(path: "/admin/join-requests/\(id)/approve")
    }

    func declineJoinRequest(id: UUID) async throws {
        try await postEmpty(path: "/admin/join-requests/\(id)/decline")
    }

    struct DemoLoginRequest: Encodable { let passphrase: String }

    func demoLogin(passphrase: String) async throws -> AuthResponse {
        let body = DemoLoginRequest(passphrase: passphrase)
        return try await post(path: "/auth/demo-login", body: body, authenticated: false)
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

    func requestToJoinClub(clubId: UUID) async throws {
        try await postEmpty(path: "/clubs/\(clubId)/join-request")
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

    struct BookSearchResult: Identifiable, Decodable {
        let id = UUID()
        let title: String
        let author: String
        let coverUrl: String?
        enum CodingKeys: String, CodingKey { case title, author, coverUrl }
    }

    func searchBooks(title: String) async -> [BookSearchResult] {
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        return (try? await get(path: "/books/search?q=\(encoded)")) ?? []
    }

    // Fetches a single book's details; the server lazily backfills Google Books
    // metadata (description / year / pages / cover) on the first call for a book.
    func bookDetails(id: UUID) async throws -> Book {
        try await get(path: "/books/\(id.uuidString)")
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

    func getUploadUrl(clubId: UUID, ext: String? = nil) async throws -> UploadUrlResponse {
        var path = "/media/upload-url?clubId=\(clubId)"
        if let ext { path += "&ext=\(ext)" }
        return try await post(path: path, body: EmptyRequest(), authenticated: true)
    }

    func getAvatarUploadUrl() async throws -> UploadUrlResponse {
        try await post(path: "/media/avatar-upload-url", body: EmptyRequest(), authenticated: true)
    }

    // MARK: - Users

    struct UpdateProfileRequest: Encodable {
        let displayName: String?
        let nickname: String?
        let avatarUrl: String?
        let preferences: UpdatePreferencesRequest?

        struct UpdatePreferencesRequest: Encodable {
            let tapToTalk: Bool?
        }
    }

    func getMe() async throws -> UserResponse {
        try await get(path: "/users/me")
    }

    func getMembers(clubId: UUID? = nil) async throws -> [UserResponse] {
        let path = clubId.map { "/users?clubId=\($0.uuidString)" } ?? "/users"
        return try await get(path: path)
    }

    func updateProfile(displayName: String?, nickname: String?, avatarUrl: String?, tapToTalk: Bool? = nil) async throws -> UserResponse {
        let prefs = tapToTalk.map { UpdateProfileRequest.UpdatePreferencesRequest(tapToTalk: $0) }
        let body = UpdateProfileRequest(displayName: displayName, nickname: nickname, avatarUrl: avatarUrl, preferences: prefs)
        return try await patch(path: "/users/me", body: body)
    }

    func uploadMedia(data: Data, to uploadUrl: URL, contentType: String) async throws {
        var request = URLRequest(url: uploadUrl)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        request.httpBody = data
        let (_, response) = try await uploadSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func uploadMediaFile(at fileUrl: URL, to uploadUrl: URL, contentType: String) async throws {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileUrl.path)[.size] as? Int) ?? 0
        var request = URLRequest(url: uploadUrl)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")
        request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        let (_, response) = try await uploadSession.upload(for: request, fromFile: fileUrl)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - Messages

    func getMessages(bookId: UUID, before: Date? = nil, limit: Int = 50) async throws -> [Message] {
        var path = "/books/\(bookId)/messages?limit=\(limit)"
        if let before {
            let iso = ISO8601DateFormatter()
            // Include fractional seconds to match server-side UtcDateTimeConverter
            // (yyyy-MM-ddTHH:mm:ss.fffZ). Without this, sub-second precision is
            // lost and pagination could skip messages on the boundary second.
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            path += "&before=\(iso.string(from: before))"
        }
        return try await get(path: path)
    }

    struct ChatReadDto: Decodable, Identifiable {
        let userId: UUID
        let displayName: String
        let avatarUrl: String?
        let lastSeenMessageId: UUID
        var heardMessageIds: [UUID] = []
        var id: UUID { userId }
    }

    func getReads(bookId: UUID) async throws -> [ChatReadDto] {
        try await get(path: "/books/\(bookId)/reads")
    }

    // MARK: - Feedback (admin / club-admin only; backed by GitHub issues)

    struct FeedbackDto: Decodable, Identifiable {
        let number: Int
        let title: String
        let state: String          // "open" | "closed"
        let htmlUrl: String
        let createdAt: Date
        var id: Int { number }
    }
    struct CreateFeedbackRequest: Encodable {
        let title: String
        let body: String
        let appVersion: String
    }

    func getFeedback(state: String) async throws -> [FeedbackDto] {
        try await get(path: "/feedback?state=\(state)")
    }

    func submitFeedback(title: String, body: String, appVersion: String) async throws -> FeedbackDto {
        try await post(path: "/feedback",
                        body: CreateFeedbackRequest(title: title, body: body, appVersion: appVersion),
                        authenticated: true)
    }

    func markRead(bookId: UUID, messageId: UUID) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/books/\(bookId)/read")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONEncoder().encode(messageId)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    // Mark a voice message heard (sticky, server-side). Fired on full playback or a
    // per-message "Mark as Heard".
    func markHeard(bookId: UUID, messageId: UUID) async throws {
        try await postEmpty(path: "/books/\(bookId)/messages/\(messageId)/heard")
    }

    // Mark every voice message in a book heard ("Mark all as heard").
    func markAllHeard(bookId: UUID) async throws {
        try await postEmpty(path: "/books/\(bookId)/heard/all")
    }

    // Upload an on-device voice transcript so a reply quoting this message can show its
    // first words to everyone (server bakes it into the reply's parentPreview).
    func uploadTranscript(messageId: UUID, text: String) async throws {
        struct Body: Encodable { let transcript: String }
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/messages/\(messageId)/transcript")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONEncoder().encode(Body(transcript: text))
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func getSavedMessages() async throws -> [SavedMessage] {
        try await get(path: "/messages/saved")
    }

    func saveMessage(messageId: UUID) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/messages/\(messageId)/save")!)
        request.httpMethod = "POST"
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func unsaveMessage(messageId: UUID) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/messages/\(messageId)/save")!)
        request.httpMethod = "DELETE"
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func reportMessage(messageId: UUID) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/messages/\(messageId)/report")!)
        request.httpMethod = "POST"
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func fetchBlockedUserIds() async throws -> [UUID] {
        try await get(path: "/users/blocked-ids")
    }

    func fetchBlockedUsers() async throws -> [UserResponse] {
        try await get(path: "/users/blocked")
    }

    func blockUser(userId: UUID) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/users/\(userId)/block")!)
        request.httpMethod = "POST"
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func unblockUser(userId: UUID) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/users/\(userId)/block")!)
        request.httpMethod = "DELETE"
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private struct EmptyRequest: Encodable {}

    // MARK: - Notifications

    struct RegisterDeviceRequest: Encodable {
        let deviceToken: String
    }

    func registerDevice(token: String) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/notifications/register")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(RegisterDeviceRequest(deviceToken: token))
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
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

    // MARK: - Admin

    struct PendingUser: Identifiable, Decodable {
        let id: UUID
        let displayName: String
        let email: String?
        let createdAt: Date
    }

    struct AdminReport: Identifiable, Decodable {
        let id: UUID
        let messageId: UUID
        let reporterName: String
        let senderName: String
        let messageType: MessageType
        let messageBody: String?
        let sentAt: Date
        let reportedAt: Date
    }

    func pendingUsers() async throws -> [PendingUser] {
        try await get(path: "/admin/pending-users")
    }

    func getReports() async throws -> [AdminReport] {
        try await get(path: "/admin/reports")
    }

    func dismissReport(id: UUID) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/admin/reports/\(id)")!)
        request.httpMethod = "DELETE"
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func deleteMessage(id: UUID) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/admin/messages/\(id)")!)
        request.httpMethod = "DELETE"
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func approveUser(id: UUID) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/admin/users/\(id)/approve")!)
        request.httpMethod = "POST"
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    struct SetRoleRequest: Encodable { let isAdmin: Bool }

    func setUserRole(id: UUID, isAdmin: Bool) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/admin/users/\(id)/set-role")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(SetRoleRequest(isAdmin: isAdmin))
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func deleteUser(id: UUID) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/admin/users/\(id)")!)
        request.httpMethod = "DELETE"
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func leaveClub(clubId: UUID) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/clubs/\(clubId)/members/me")!)
        request.httpMethod = "DELETE"
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func deleteClub(clubId: UUID) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/admin/clubs/\(clubId)")!)
        request.httpMethod = "DELETE"
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    struct SetClubAdminRequest: Encodable { let isClubAdmin: Bool }

    func setClubAdmin(userId: UUID, clubId: UUID, isClubAdmin: Bool) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/admin/clubs/\(clubId)/members/\(userId)/set-club-admin")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(SetClubAdminRequest(isClubAdmin: isClubAdmin))
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func removeMember(userId: UUID, clubId: UUID) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + "/admin/clubs/\(clubId)/members/\(userId)")!)
        request.httpMethod = "DELETE"
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func deleteMyAccount() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("/auth/me"))
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

    // Single in-flight refresh task — multiple concurrent 401s coalesce so we don't
    // burn through rotated refresh tokens with parallel refreshes.
    private enum RefreshOutcome { case refreshed, rejected, transient }
    private var refreshTask: Task<RefreshOutcome, Never>?
    private let refreshLock = NSLock()

    // Refresh the access token if it's expired or within 2 minutes of expiry.
    // Returns true if the token is valid afterwards. Call before opening long-lived
    // connections (SignalR) where 401 mid-stream is messier than refreshing up-front.
    func ensureFreshToken() async -> Bool {
        guard TokenStore.shared.refreshToken != nil else { return TokenStore.shared.token != nil }
        if !shouldRefreshPreemptively() { return TokenStore.shared.token != nil }
        switch await attemptRefresh() {
        case .refreshed: return true
        case .transient: return TokenStore.shared.token != nil  // keep current token; try again later
        case .rejected: handleAuthFailure(); return false       // token is dead — sign out
        }
    }

    private func shouldRefreshPreemptively() -> Bool {
        guard let token = TokenStore.shared.token else { return true }
        let parts = token.components(separatedBy: ".")
        guard parts.count == 3 else { return true }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else { return true }
        return Date(timeIntervalSince1970: exp).timeIntervalSinceNow < 120
    }

    private func attemptRefresh() async -> RefreshOutcome {
        // Coalesce concurrent 401s onto a single in-flight refresh. The locked
        // bookkeeping lives in synchronous helpers — NSLock can't be held across
        // an `await` and isn't callable from an async context under Swift 6.
        let (task, isOwner) = existingOrNewRefreshTask()
        let result = await task.value
        if isOwner { clearRefreshTask() }
        return result
    }

    private func existingOrNewRefreshTask() -> (task: Task<RefreshOutcome, Never>, isOwner: Bool) {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        if let existing = refreshTask { return (existing, false) }
        let task = Task<RefreshOutcome, Never> { [weak self] in
            guard let self, let rt = TokenStore.shared.refreshToken else { return .rejected }
            do {
                let response = try await self.refresh(refreshToken: rt)
                TokenStore.shared.token = response.accessToken
                TokenStore.shared.refreshToken = response.refreshToken
                return .refreshed
            } catch RefreshError.rejected {
                return .rejected
            } catch {
                return .transient
            }
        }
        refreshTask = task
        return (task, true)
    }

    private func clearRefreshTask() {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        refreshTask = nil
    }

    private func handleAuthFailure() {
        TokenStore.shared.token = nil
        TokenStore.shared.refreshToken = nil
        onUnauthorized?()
    }

    private func get<Response: Decodable>(path: String, retried: Bool = false) async throws -> Response {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        request.httpMethod = "GET"
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 {
            if !retried {
                switch await attemptRefresh() {
                case .refreshed: return try await get(path: path, retried: true)
                case .transient: throw URLError(.timedOut)  // keep session; surface as a transient error
                case .rejected: break                        // fall through to sign out
                }
            }
            handleAuthFailure(); throw URLError(.userAuthenticationRequired)
        }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try decoder.decode(Response.self, from: data)
    }

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        authenticated: Bool,
        retried: Bool = false
    ) async throws -> Response {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated, let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 {
            if authenticated, !retried {
                switch await attemptRefresh() {
                case .refreshed: return try await post(path: path, body: body, authenticated: authenticated, retried: true)
                case .transient: throw URLError(.timedOut)
                case .rejected: break
                }
            }
            if authenticated { handleAuthFailure() }
            throw URLError(.userAuthenticationRequired)
        }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try decoder.decode(Response.self, from: data)
    }

    private func postEmpty(path: String, retried: Bool = false) async throws {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        request.httpMethod = "POST"
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 {
            if !retried {
                switch await attemptRefresh() {
                case .refreshed: return try await postEmpty(path: path, retried: true)
                case .transient: throw URLError(.timedOut)
                case .rejected: break
                }
            }
            handleAuthFailure(); throw URLError(.userAuthenticationRequired)
        }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
    }

    private func patch<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        retried: Bool = false
    ) async throws -> Response {
        var request = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = TokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 {
            if !retried {
                switch await attemptRefresh() {
                case .refreshed: return try await patch(path: path, body: body, retried: true)
                case .transient: throw URLError(.timedOut)
                case .rejected: break
                }
            }
            handleAuthFailure(); throw URLError(.userAuthenticationRequired)
        }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try decoder.decode(Response.self, from: data)
    }
}
