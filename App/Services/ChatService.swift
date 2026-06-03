import Foundation
import SignalRClient

enum ChatError: Error { case notConnected }

final class ChatService: ObservableObject {
    static let shared = ChatService()

    nonisolated(unsafe) private var connection: HubConnection?
    nonisolated(unsafe) private(set) var currentBookId: UUID?

    var onMessageReceived: ((Message) -> Void)?
    var onMessageDeleted: ((UUID) -> Void)?

    private init() {}

    var isConnected: Bool { connection != nil }

    nonisolated func connect(bookId: UUID) async {
        guard let token = TokenStore.shared.token else { return }

        if currentBookId != bookId {
            await disconnect()
        }

        guard connection == nil else { return }

        currentBookId = bookId

        #if targetEnvironment(simulator)
        let baseUrl = "http://localhost:5235"
        #else
        let baseUrl = "https://oldmansbookclub-api.azurewebsites.net"
        #endif
        let url = "\(baseUrl)/hubs/chat?access_token=\(token)"

        connection = HubConnectionBuilder()
            .withUrl(url: url)
            .withAutomaticReconnect(retryDelays: [2, 5, 10, 30])
            .withKeepAliveInterval(keepAliveInterval: 15)
            .build()

        let onMessage = onMessageReceived
        await connection?.on("NewMessage") { (dto: MessageDto) async in
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
                isForwarded: dto.isForwarded
            )
            await MainActor.run {
                onMessage?(message)
            }
        }

        let onDeleted = onMessageDeleted
        await connection?.on("MessageDeleted") { (payload: DeletedPayload) async in
            await MainActor.run {
                onDeleted?(payload.messageId)
            }
        }

        await connection?.onReconnected {
            try? await self.connection?.invoke(method: "JoinBook", arguments: bookId.uuidString)
        }

        await connection?.onClosed { [weak self] _ in
            self?.connection = nil
            self?.currentBookId = nil
        }

        do {
            try await connection?.start()
        } catch {
            connection = nil
            currentBookId = nil
            return
        }
        try? await connection?.invoke(method: "JoinBook", arguments: bookId.uuidString)
    }

    nonisolated func sendText(bookId: UUID, body: String) async throws {
        guard let conn = connection else { throw ChatError.notConnected }
        try await conn.invoke(method: "SendTextMessage", arguments: bookId.uuidString, body)
    }

    nonisolated func sendPhoto(bookId: UUID, mediaUrl: String) async throws {
        guard let conn = connection else { throw ChatError.notConnected }
        try await conn.invoke(method: "SendPhotoMessage", arguments: bookId.uuidString, mediaUrl)
    }

    nonisolated func sendVideo(bookId: UUID, mediaUrl: String) async throws {
        guard let conn = connection else { throw ChatError.notConnected }
        try await conn.invoke(method: "SendVideoMessage", arguments: bookId.uuidString, mediaUrl)
    }

    nonisolated func sendVoice(bookId: UUID, mediaUrl: String, durationSeconds: Int) async throws {
        guard let conn = connection else { throw ChatError.notConnected }
        try await conn.invoke(method: "SendVoiceMessage", arguments: bookId.uuidString, mediaUrl, durationSeconds)
    }

    nonisolated func deleteMessage(messageId: UUID) async throws {
        guard let conn = connection else { throw ChatError.notConnected }
        try await conn.invoke(method: "DeleteMessage", arguments: messageId.uuidString)
    }

    nonisolated func forwardMessage(bookId: UUID, messageId: UUID) async throws {
        guard let conn = connection else { throw ChatError.notConnected }
        try await conn.invoke(method: "ForwardMessage", arguments: bookId.uuidString, messageId.uuidString)
    }

    nonisolated func disconnect() async {
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

    var sentAtDate: Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: sentAt) ?? Date()
    }
}

private struct DeletedPayload: Decodable {
    let messageId: UUID
}
