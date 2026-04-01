import Foundation
import SignalRClient

@MainActor
final class ChatService: ObservableObject {
    static let shared = ChatService()

    private var connection: HubConnection?
    private(set) var currentClubId: UUID?

    var onMessageReceived: ((Message) -> Void)?

    private init() {}

    func connect(clubId: UUID) async {
        guard let token = TokenStore.shared.token else { return }

        // Disconnect from previous club if different
        if currentClubId != clubId {
            await disconnect()
        }

        guard connection == nil else { return }

        currentClubId = clubId

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
            try await connection?.invoke(method: "JoinClub", arguments: [clubId.uuidString])
        } catch {
            print("SignalR connect error: \(error)")
        }
    }

    func sendText(clubId: UUID, body: String) async {
        do {
            try await connection?.invoke(method: "SendTextMessage", arguments: [clubId.uuidString, body])
        } catch {
            print("SignalR send error: \(error)")
        }
    }

    func disconnect() async {
        try? await connection?.stop()
        connection = nil
        currentClubId = nil
    }
}

// Mirrors the server MessageDto for SignalR deserialization
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
