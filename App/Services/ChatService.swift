import Foundation
import SignalRClient

final class ChatService: ObservableObject {
    static let shared = ChatService()

    nonisolated(unsafe) private var connection: HubConnection?
    nonisolated(unsafe) private(set) var currentBookId: UUID?

    var onMessageReceived: ((Message) -> Void)?
    var onMessageDeleted: ((UUID) -> Void)?

    private init() {}

    nonisolated func connect(bookId: UUID) async {
        guard let token = TokenStore.shared.token else { return }

        if currentBookId != bookId {
            await disconnect()
        }

        guard connection == nil else { return }

        currentBookId = bookId

        let url = "https://oldmansbookclub-api.azurewebsites.net/hubs/chat?access_token=\(token)"

        connection = HubConnectionBuilder()
            .withUrl(url: url)
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

        try? await connection?.start()
        try? await connection?.invoke(method: "JoinBook", arguments: bookId.uuidString)
    }

    nonisolated func sendText(bookId: UUID, body: String) async throws {
        try await connection?.invoke(method: "SendTextMessage", arguments: bookId.uuidString, body)
    }

    nonisolated func sendPhoto(bookId: UUID, mediaUrl: String) async throws {
        try await connection?.invoke(method: "SendPhotoMessage", arguments: bookId.uuidString, mediaUrl)
    }

    nonisolated func sendVoice(bookId: UUID, mediaUrl: String, durationSeconds: Int) async throws {
        try await connection?.invoke(method: "SendVoiceMessage", arguments: bookId.uuidString, mediaUrl, durationSeconds)
    }

    nonisolated func deleteMessage(messageId: UUID) async throws {
        try await connection?.invoke(method: "DeleteMessage", arguments: messageId.uuidString)
    }

    nonisolated func forwardMessage(bookId: UUID, messageId: UUID) async throws {
        try await connection?.invoke(method: "ForwardMessage", arguments: bookId.uuidString, messageId.uuidString)
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
