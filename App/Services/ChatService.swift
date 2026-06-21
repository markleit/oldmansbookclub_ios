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
        // Refresh access token if near expiry — SignalR's `?access_token=` is bound
        // at handshake, and a mid-stream 401 won't auto-recover.
        _ = await APIClient.shared.ensureFreshToken()
        guard let token = TokenStore.shared.token else { return }

        currentBookId = bookId

        #if targetEnvironment(simulator)
        let baseUrl = "http://localhost:5235"
        #else
        let baseUrl = "https://oldmansbookclub-api.azurewebsites.net"
        #endif
        let url = "\(baseUrl)/hubs/chat?access_token=\(token)"

        let conn = HubConnectionBuilder()
            .withUrl(url: url)
            .withAutomaticReconnect(retryDelays: [2, 5, 10, 30])
            .withKeepAliveInterval(keepAliveInterval: 5)
            .build()
        connection = conn

        await conn.on("NewMessage") { [weak self] (dto: MessageDto) async in
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
                clientId: dto.clientId
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

        await conn.on("UserTyping") { [weak self] (payload: UserTypingPayload) async in
            guard let handler = await self?.onUserTyping else { return }
            await MainActor.run { handler(payload) }
        }

        await conn.onReconnected { [weak self] in
            await self?.rejoinBookGroup()
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

    // Replies go through dedicated *Reply hub methods (SignalR matches by exact argument
    // count, so we can't add an optional trailing arg to the originals without breaking
    // older clients). The non-reply path keeps the original method + arity unchanged.
    func sendText(bookId: UUID, body: String, clientId: UUID, parentMessageId: UUID? = nil) async throws {
        do {
            let conn = try await readyConnection()
            if let pid = parentMessageId {
                try await conn.invoke(method: "SendTextReply", arguments: bookId.uuidString, body, clientId.uuidString, pid.uuidString)
            } else {
                try await conn.invoke(method: "SendTextMessage", arguments: bookId.uuidString, body, clientId.uuidString)
            }
        } catch { throw translateInvokeError(error) }
    }

    func sendPhoto(bookId: UUID, mediaUrl: String, clientId: UUID, parentMessageId: UUID? = nil) async throws {
        do {
            let conn = try await readyConnection()
            if let pid = parentMessageId {
                try await conn.invoke(method: "SendPhotoReply", arguments: bookId.uuidString, mediaUrl, clientId.uuidString, pid.uuidString)
            } else {
                try await conn.invoke(method: "SendPhotoMessage", arguments: bookId.uuidString, mediaUrl, clientId.uuidString)
            }
        } catch { throw translateInvokeError(error) }
    }

    func sendVideo(bookId: UUID, mediaUrl: String, clientId: UUID, parentMessageId: UUID? = nil) async throws {
        do {
            let conn = try await readyConnection()
            if let pid = parentMessageId {
                try await conn.invoke(method: "SendVideoReply", arguments: bookId.uuidString, mediaUrl, clientId.uuidString, pid.uuidString)
            } else {
                try await conn.invoke(method: "SendVideoMessage", arguments: bookId.uuidString, mediaUrl, clientId.uuidString)
            }
        } catch { throw translateInvokeError(error) }
    }

    func sendVoice(bookId: UUID, mediaUrl: String, durationSeconds: Int, clientId: UUID, parentMessageId: UUID? = nil) async throws {
        do {
            let conn = try await readyConnection()
            if let pid = parentMessageId {
                try await conn.invoke(method: "SendVoiceReply", arguments: bookId.uuidString, mediaUrl, durationSeconds, clientId.uuidString, pid.uuidString)
            } else {
                try await conn.invoke(method: "SendVoiceMessage", arguments: bookId.uuidString, mediaUrl, durationSeconds, clientId.uuidString)
            }
        } catch { throw translateInvokeError(error) }
    }

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

private struct MessageDto: Decodable {
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

    var sentAtDate: Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: sentAt) ?? Date()
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

struct UserTypingPayload: Decodable {
    let bookId: UUID
    let userId: UUID
    let displayName: String
    let isRecording: Bool
}
