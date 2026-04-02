import Foundation
import SignalRClient

@MainActor
final class ChatService: ObservableObject {
    static let shared = ChatService()

    private var connection: HubConnection?
    private(set) var currentBookId: UUID?

    var onMessageReceived: ((Message) -> Void)?

    private init() {}

    func connect(bookId: UUID) async {
        guard let token = TokenStore.shared.token else { return }

        if currentBookId != bookId {
            await disconnect()
        }

        guard connection == nil else { return }

        currentBookId = bookId

        let url = "https://oldmansbookclub-api.azurewebsites.net/hubs/chat?access_token=\(token)"

        connection = HubConnectionBuilder(url: URL(string: url)!)
            .build()

        connection?.on("NewMessage") { [weak self] (dto: MessageDto) in
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
            Task { @MainActor in
                self?.onMessageReceived?(message)
            }
        }

        do {
            try await connection?.start()
            try await connection?.invoke(method: "JoinBook", arguments: [bookId.uuidString])
        } catch {
            print("SignalR connect error: \(error)")
        }
    }

    func sendText(bookId: UUID, body: String) async {
        do {
            try await connection?.invoke(method: "SendTextMessage", arguments: [bookId.uuidString, body])
        } catch {
            print("SignalR send error: \(error)")
        }
    }

    func disconnect() async {
        try? await connection?.stop()
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
