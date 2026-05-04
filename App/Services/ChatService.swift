import Foundation
import SignalRClient

final class ChatService: ObservableObject {
    static let shared = ChatService()

    nonisolated(unsafe) private var connection: HubConnection?
    nonisolated(unsafe) private(set) var currentBookId: UUID?

    var onMessageReceived: ((Message) -> Void)?

    private init() {}

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
            .build()

        await connection?.on("NewMessage") { [weak self] (dto: MessageDto) async in
            let message = Message(
                id: dto.id,
                clubId: dto.clubId,
                senderId: dto.senderId,
                senderName: dto.senderName,
                type: MessageType(rawValue: dto.type) ?? .text,
                body: dto.body,
                mediaUrl: dto.mediaUrl,
                durationSeconds: dto.durationSeconds,
                sentAt: dto.sentAt
            )
            await MainActor.run {
                self?.onMessageReceived?(message)
            }
        }

        do {
            try await connection?.start()
            try await connection?.invoke(method: "JoinBook", arguments: bookId.uuidString)
        } catch {
            print("SignalR connect error: \(error)")
        }
    }

    nonisolated func sendText(bookId: UUID, body: String) async {
        do {
            try await connection?.invoke(method: "SendTextMessage", arguments: bookId.uuidString, body)
        } catch {
            print("SignalR send error: \(error)")
        }
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
    let sentAt: Date
}
