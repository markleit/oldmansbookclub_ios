import Foundation
import SignalRClient

enum ChatError: Error {
    case notConnected
    // Server-side HubException — carries the message the server threw so the UI
    // can surface it (rate limit, validation failures, etc.) instead of a generic
    // "connection lost" string.
    case serverError(String)
}

private func translateInvokeError(_ error: Error) -> Error {
    if let sigr = error as? SignalRError, case .invocationError(let msg) = sigr {
        return ChatError.serverError(msg)
    }
    return error
}

actor ChatService {
    static let shared = ChatService()

    private var connection: HubConnection?
    private var currentBookId: UUID?
    // Tracks an in-flight connect so concurrent callers (and send retries) can await it
    private var pendingConnect: Task<Void, Never>?
    // Set by didBecomeActive — after a long iOS background the lib's connection.state()
    // can report .Connected even when the underlying WebSocket is dead, so we don't
    // trust state alone; the next send-side call forces a full disconnect + reconnect.
    private var requiresRebuild: Bool = false

    // Callbacks are set by the view model. Stored here so we can rewire them after a
    // connection rebuild without losing the active handler.
    private var onMessageReceived: ((Message) -> Void)?
    private var onMessageDeleted: ((UUID) -> Void)?
    private var onMessageEdited: ((EditedPayload) -> Void)?
    private var onReadReceipt: ((ReadReceiptPayload) -> Void)?
    private var onHeardReceipt: ((HeardReceiptPayload) -> Void)?
    private var onReactionReceipt: ((ReactionReceiptPayload) -> Void)?
    private var onUserTyping: ((UserTypingPayload) -> Void)?

    private init() {}

    var isConnected: Bool { connection != nil }
    var activeBookId: UUID? { currentBookId }

    func setOnMessageReceived(_ handler: @escaping (Message) -> Void) {
        onMessageReceived = handler
    }

    func setOnMessageDeleted(_ handler: @escaping (UUID) -> Void) {
        onMessageDeleted = handler
    }

    func setOnMessageEdited(_ handler: @escaping (EditedPayload) -> Void) {
        onMessageEdited = handler
    }

    func setOnReadReceipt(_ handler: @escaping (ReadReceiptPayload) -> Void) {
        onReadReceipt = handler
    }

    func setOnHeardReceipt(_ handler: @escaping (HeardReceiptPayload) -> Void) {
        onHeardReceipt = handler
    }

    func setOnReactionReceipt(_ handler: @escaping (ReactionReceiptPayload) -> Void) {
        onReactionReceipt = handler
    }

    func setOnUserTyping(_ handler: @escaping (UserTypingPayload) -> Void) {
        onUserTyping = handler
    }

    // Fire-and-forget typing/recording ping (best-effort; never throws into the UI).
    // nonisolated so @MainActor callers can fire it synchronously; the actual send
    // hops onto the actor inside the Task.
    nonisolated func sendTyping(bookId: UUID, isRecording: Bool) {
        Task { try? await readyConnection().invoke(method: "Typing", arguments: bookId.uuidString, isRecording) }
    }

    // Called from the iOS foreground transition. Marks the existing connection as
    // suspect so the next send-side call forces a rebuild before invoking, regardless
    // of what the lib's state() reports.
    func markStaleAfterBackground() {
        requiresRebuild = true
    }

    func connect(bookId: UUID) async {
        // Already connected and fully started for this book — nothing to do
        if currentBookId == bookId, connection != nil, pendingConnect == nil { return }

        // A connect for this book is already in flight — just await it
        if currentBookId == bookId, let pending = pendingConnect {
            await pending.value
            return
        }

        if currentBookId != bookId {
            pendingConnect = nil
            await disconnect()
        }

        guard connection == nil else { return }

        let task = Task { await self._startConnection(bookId: bookId) }
        pendingConnect = task
        await task.value
        pendingConnect = nil
    }

    private func _startConnection(bookId: UUID) async {
        // Don't connect while signed out. The access token is NOT baked into the URL anymore —
        // it's supplied per-(re)connect by the accessTokenFactory below, which refreshes it. So an
        // automatic reconnect after the ~1h access token expires fetches a FRESH token instead of
        // reusing the stale one, which previously killed sends until an app relaunch (#103).
        guard TokenStore.shared.token != nil else { return }

        currentBookId = bookId

        // Same resolver as APIClient (#120) — these two must never disagree, or chat would keep
        // talking to production while REST calls went somewhere else.
        var url = "\(ServerEnvironment.baseURLString)/hubs/chat"

        // #25 — tell the hub which physical device this connection is, so a message this device
        // sends can be excluded from its OWN push without also excluding this account's other
        // devices. Omitted (not empty-string) if this device hasn't registered a token yet — the
        // server treats that the same as an unupdated client and falls back to excluding the
        // whole sender.
        if let deviceToken = TokenStore.shared.registeredDeviceToken,
           let encoded = deviceToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            url += "?deviceId=\(encoded)"
        }

        // Called on every negotiate (including auto-reconnect) and on a 401 — refresh, then hand
        // over the current token. The client appends it as `access_token` on the transport URL.
        var options = HttpConnectionOptions()
        options.accessTokenFactory = {
            _ = await APIClient.shared.ensureFreshToken()
            return TokenStore.shared.token
        }

        let conn = HubConnectionBuilder()
            .withUrl(url: url, options: options)
            .withAutomaticReconnect(retryDelays: [2, 5, 10, 30])
            .withKeepAliveInterval(keepAliveInterval: 5)
            .build()
        connection = conn

        await conn.on("NewMessage") { [weak self] (dto: ChatMessageDto) async in
            let message = Message(
                id: dto.id,
                clubId: dto.clubId,
                senderId: dto.senderId,
                senderName: dto.senderName,
                type: MessageType(rawValue: dto.type) ?? .text,
                body: dto.body,
                mediaUrl: dto.mediaUrl,
                durationSeconds: dto.durationSeconds,
                sentAt: dto.sentAtDate,
                isDeleted: dto.isDeleted,
                isForwarded: dto.isForwarded,
                clientId: dto.clientId,
                parentMessageId: dto.parentMessageId,
                parentSenderName: dto.parentSenderName,
                parentPreview: dto.parentPreview,
                parentSentAt: dto.parentSentAtDate,
                transcript: dto.transcript
            )
            guard let handler = await self?.onMessageReceived else { return }
            await MainActor.run { handler(message) }
        }

        await conn.on("MessageDeleted") { [weak self] (payload: DeletedPayload) async in
            guard let handler = await self?.onMessageDeleted else { return }
            await MainActor.run { handler(payload.messageId) }
        }

        await conn.on("MessageEdited") { [weak self] (payload: EditedPayload) async in
            guard let handler = await self?.onMessageEdited else { return }
            await MainActor.run { handler(payload) }
        }

        await conn.on("ReadReceipt") { [weak self] (payload: ReadReceiptPayload) async in
            guard let handler = await self?.onReadReceipt else { return }
            await MainActor.run { handler(payload) }
        }

        await conn.on("HeardReceipt") { [weak self] (payload: HeardReceiptPayload) async in
            guard let handler = await self?.onHeardReceipt else { return }
            await MainActor.run { handler(payload) }
        }

        await conn.on("ReactionReceipt") { [weak self] (payload: ReactionReceiptPayload) async in
            guard let handler = await self?.onReactionReceipt else { return }
            await MainActor.run { handler(payload) }
        }

        await conn.on("UserTyping") { [weak self] (payload: UserTypingPayload) async in
            guard let handler = await self?.onUserTyping else { return }
            await MainActor.run { handler(payload) }
        }

        await conn.onReconnected { [weak self] in
            await self?.rejoinBookGroup()
            // Connectivity is back — drain any receipt that failed while it was gone (#119).
            await ReceiptQueue.shared.flush()
        }

        await conn.onClosed { [weak self] _ in
            await self?.handleConnectionClosed()
        }

        do {
            try await conn.start()
        } catch {
            connection = nil
            currentBookId = nil
            return
        }
        try? await conn.invoke(method: "JoinBook", arguments: bookId.uuidString)
    }

    private func rejoinBookGroup() async {
        guard let conn = connection, let bookId = currentBookId else { return }
        try? await conn.invoke(method: "JoinBook", arguments: bookId.uuidString)
    }

    private func handleConnectionClosed() {
        connection = nil
        currentBookId = nil
    }

    // Waits for any in-flight connect to finish, then validates the connection is ready.
    // All send methods call this so they never race against an unstarted connection.
    //
    // After long iOS background suspension the underlying WebSocket can die without
    // the SignalR client noticing — invoke() then completes locally without ever
    // reaching the server (silent message loss). Two protections:
    //   1. requiresRebuild flag set by didBecomeActive — always tear down + rebuild
    //      on the first send after foreground, regardless of state().
    //   2. state() check — catches the case where the lib already noticed.
    private func readyConnection() async throws -> HubConnection {
        await pendingConnect?.value
        let needsRebuild: Bool
        if requiresRebuild {
            needsRebuild = true
        } else if let conn = connection {
            needsRebuild = await conn.state() != .Connected
        } else {
            needsRebuild = false
        }
        if needsRebuild, let bookId = currentBookId {
            requiresRebuild = false
            await disconnect()
            await connect(bookId: bookId)
        }
        guard let conn = connection else { throw ChatError.notConnected }
        return conn
    }

    // NOTE: sending no longer goes through the hub from this client (#131) — see
    // APIClient.sendMessage / BackgroundUploadService.sendMessage, which POST over REST
    // instead, so a send doesn't need a live WebSocket and isn't stranded by backgrounding.
    // The server's hub SendTextMessage/SendPhotoMessage/SendVideoMessage/SendVoiceMessage (and
    // their *Reply variants) stay in place for older installed clients — this actor just
    // doesn't invoke them anymore.

    func deleteMessage(messageId: UUID) async throws {
        do { try await readyConnection().invoke(method: "DeleteMessage", arguments: messageId.uuidString) }
        catch { throw translateInvokeError(error) }
    }

    func editMessage(messageId: UUID, body: String) async throws {
        do { try await readyConnection().invoke(method: "EditTextMessage", arguments: messageId.uuidString, body) }
        catch { throw translateInvokeError(error) }
    }

    func forwardMessage(bookId: UUID, messageId: UUID) async throws {
        do { try await readyConnection().invoke(method: "ForwardMessage", arguments: bookId.uuidString, messageId.uuidString) }
        catch { throw translateInvokeError(error) }
    }

    func disconnect() async {
        await connection?.stop()
        connection = nil
        currentBookId = nil
    }
}

// Internal rather than private so the JSON contract tests can decode a server-generated fixture
// through it (#126). This is the SECOND Swift mirror of the server's MessageDto — the REST one is
// `Message` in Models.swift — and the two differ in ways that matter: this one has no
// senderAvatarUrl and no reactions, its isDeleted/isForwarded are non-optional, its dates are
// strings parsed by a formatter that only accepts fractional seconds, and it arrives camelCase
// (SignalR) rather than snake_case (REST). Two mirrors of one record with different tolerance is
// the most likely place in the app for silent drift, which is exactly why it is now under test.
struct ChatMessageDto: Decodable {
    let id: UUID
    let clubId: UUID
    let senderId: UUID
    let senderName: String
    let type: String
    let body: String?
    let mediaUrl: String?
    let durationSeconds: Int?
    let sentAt: String
    let isDeleted: Bool
    let isForwarded: Bool
    let clientId: UUID?
    let parentMessageId: UUID?
    let parentSenderName: String?
    let parentPreview: String?
    let parentSentAt: String?
    let transcript: String?

    var sentAtDate: Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: sentAt) ?? Date()
    }

    var parentSentAtDate: Date? {
        guard let parentSentAt else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: parentSentAt)
    }
}

private struct DeletedPayload: Decodable {
    let messageId: UUID
}

struct EditedPayload: Decodable {
    let messageId: UUID
    let bookId: UUID
    let body: String
}

// SignalR receipt events (camelCase payload). Live read/heard receipt updates.
struct ReadReceiptPayload: Decodable {
    let bookId: UUID
    let userId: UUID
    let displayName: String
    let avatarUrl: String?
    let lastSeenMessageId: UUID
}

struct HeardReceiptPayload: Decodable {
    let bookId: UUID
    let userId: UUID
    let displayName: String
    let avatarUrl: String?
    let messageIds: [UUID]
}

// #47 — a reaction was set/switched (emoji != nil) or removed (emoji == nil).
struct ReactionReceiptPayload: Decodable {
    let bookId: UUID
    let messageId: UUID
    let userId: UUID
    let displayName: String
    let emoji: String?
}

struct UserTypingPayload: Decodable {
    let bookId: UUID
    let userId: UUID
    let displayName: String
    let isRecording: Bool
}
