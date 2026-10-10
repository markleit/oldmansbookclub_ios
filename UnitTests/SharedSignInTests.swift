import XCTest
@testable import OldMansBookClub

/// #204 (PR 3) — the Share extension's sign-in. The access token lasts an hour; before this the
/// extension never refreshed it, so sharing after the app had been idle for an hour failed with
/// "sign in" even though the session was fine.
final class SharedSignInTests: XCTestCase {

    // MARK: - JWTExpiry

    private func jwt(expiresIn seconds: TimeInterval, from now: Date = Date()) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["exp": now.addingTimeInterval(seconds).timeIntervalSince1970])
        let b64 = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(b64).sig"
    }

    func testAFreshTokenIsUsedAsIs() {
        XCTAssertFalse(JWTExpiry.needsRefresh(jwt(expiresIn: 3600)))
    }

    func testAnExpiredTokenNeedsRefreshing() {
        XCTAssertTrue(JWTExpiry.needsRefresh(jwt(expiresIn: -10)))
    }

    func testATokenAboutToExpireIsRefreshedBeforeSending() {
        // Within a minute of expiry: refresh first rather than send a request that's refused.
        XCTAssertTrue(JWTExpiry.needsRefresh(jwt(expiresIn: 30)))
    }

    func testAnUnreadableTokenNeedsRefreshing() {
        XCTAssertTrue(JWTExpiry.needsRefresh("not-a-jwt"))
        XCTAssertNil(JWTExpiry.expiresAt("a.!!!.c"))
    }

    // MARK: - SignInSession

    private final class FakeStore: SignInStore, @unchecked Sendable {
        private let lock = NSLock()
        private var access: String?
        private let refresh: String?
        private(set) var saved: [String] = []
        init(access: String?, refresh: String?) { self.access = access; self.refresh = refresh }
        func accessToken() -> String? { lock.withLock { access } }
        func refreshToken() -> String? { refresh }
        func saveAccessToken(_ token: String) { lock.withLock { access = token; saved.append(token) } }
        func replaceAccessToken(_ token: String) { lock.withLock { access = token } }
    }

    private let base = URL(string: "https://share.test")!

    override func tearDown() {
        StubRefreshProtocol.reset()
        super.tearDown()
    }

    private func session(_ store: FakeStore) -> SignInSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubRefreshProtocol.self]
        return SignInSession(baseURL: base, store: store, session: URLSession(configuration: config))
    }

    func testAnExpiredTokenIsRefreshedOnceAndSavedForTheApp() async throws {
        let fresh = jwt(expiresIn: 3600)
        StubRefreshProtocol.respond(status: 200, json: ["access_token": fresh, "refresh_token": "rt"])
        let store = FakeStore(access: jwt(expiresIn: -60), refresh: "rt")

        let token = try await session(store).accessToken()

        XCTAssertEqual(token, fresh)
        XCTAssertEqual(store.saved, [fresh])   // written back, so the app uses it too
        XCTAssertEqual(StubRefreshProtocol.requests.count, 1)
        let body = try JSONSerialization.jsonObject(with: StubRefreshProtocol.requests[0].body) as? [String: String]
        XCTAssertEqual(body?["refresh_token"], "rt")
        XCTAssertEqual(StubRefreshProtocol.requests[0].path, "/auth/refresh")
    }

    func testAFreshTokenMakesNoRefreshCall() async throws {
        let store = FakeStore(access: jwt(expiresIn: 3600), refresh: "rt")

        _ = try await session(store).accessToken()

        XCTAssertTrue(StubRefreshProtocol.requests.isEmpty)
    }

    func testConcurrentRequestsShareOneRefresh() async throws {
        // The share sheet loads books and clubs at the same time; both need the token.
        StubRefreshProtocol.respond(status: 200, json: ["access_token": jwt(expiresIn: 3600)], delay: 0.3)
        let signIn = session(FakeStore(access: jwt(expiresIn: -60), refresh: "rt"))

        async let a = signIn.accessToken()
        async let b = signIn.accessToken()
        let (ta, tb) = try await (a, b)

        XCTAssertEqual(ta, tb)
        XCTAssertEqual(StubRefreshProtocol.requests.count, 1)
    }

    func testARefusedRefreshMeansSignedOut() async {
        StubRefreshProtocol.respond(status: 401, json: [:])
        let store = FakeStore(access: jwt(expiresIn: -60), refresh: "revoked")

        await assertThrows(SignInError.signedOut) { try await self.session(store).accessToken() }
        XCTAssertTrue(store.saved.isEmpty)
    }

    func testAServerHiccupDuringRefreshIsNotASignOut() async {
        // Only an explicit 401/403 ends the session — the same rule as the app. A 503 telling the
        // user to "sign in" would be wrong and would send them to do something that can't help.
        StubRefreshProtocol.respond(status: 503, json: [:])

        await assertThrows(SignInError.unreachable) {
            try await self.session(FakeStore(access: self.jwt(expiresIn: -60), refresh: "rt")).accessToken()
        }
    }

    func testNoNetworkDuringRefreshIsNotASignOut() async {
        StubRefreshProtocol.fail(with: URLError(.notConnectedToInternet))

        await assertThrows(SignInError.unreachable) {
            try await self.session(FakeStore(access: self.jwt(expiresIn: -60), refresh: "rt")).accessToken()
        }
    }

    func testNoStoredSessionIsSignedOut() async {
        await assertThrows(SignInError.signedOut) {
            try await self.session(FakeStore(access: nil, refresh: nil)).accessToken()
        }
    }

    func testARejectedTokenIsRefreshedEvenIfItLooksValid() async throws {
        // The server refused a token whose `exp` hadn't passed (clock skew, a secret rotation).
        let fresh = jwt(expiresIn: 3600)
        StubRefreshProtocol.respond(status: 200, json: ["access_token": fresh])
        let rejected = jwt(expiresIn: 1800)
        let store = FakeStore(access: rejected, refresh: "rt")

        let token = try await session(store).tokenAfterRejection(of: rejected)

        XCTAssertEqual(token, fresh)
        XCTAssertEqual(StubRefreshProtocol.requests.count, 1)
    }

    func testARejectionAfterSomeoneElseRefreshedUsesTheirToken() async throws {
        // The app (or a concurrent request) refreshed in the meantime: use that, don't refresh again.
        let rejected = jwt(expiresIn: 1800)
        let store = FakeStore(access: rejected, refresh: "rt")
        let theirs = jwt(expiresIn: 3600)
        store.replaceAccessToken(theirs)

        let token = try await session(store).tokenAfterRejection(of: rejected)

        XCTAssertEqual(token, theirs)
        XCTAssertTrue(StubRefreshProtocol.requests.isEmpty)
    }

    private func assertThrows(_ expected: SignInError, _ body: @escaping () async throws -> String,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected), got a token", file: file, line: line)
        } catch let error as SignInError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

/// Answers every request with a scripted response and records what was asked.
final class StubRefreshProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded { let path: String; let body: Data }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var json: [String: Any] = [:]
    nonisolated(unsafe) private static var delay: TimeInterval = 0
    nonisolated(unsafe) private static var failure: Error?
    nonisolated(unsafe) private static var recorded: [Recorded] = []

    static var requests: [Recorded] { lock.withLock { recorded } }

    static func respond(status: Int, json: [String: Any], delay: TimeInterval = 0) {
        lock.withLock { self.status = status; self.json = json; self.delay = delay; failure = nil }
    }

    static func fail(with error: Error) { lock.withLock { failure = error } }

    static func reset() {
        lock.withLock { status = 200; json = [:]; delay = 0; failure = nil; recorded = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let (status, json, delay, failure) = Self.lock.withLock {
            Self.recorded.append(Recorded(path: request.url?.path ?? "", body: body))
            return (Self.status, Self.json, Self.delay, Self.failure)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            if let failure { client?.urlProtocol(self, didFailWithError: failure); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
