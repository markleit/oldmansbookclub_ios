import Foundation

@MainActor
final class ClubViewModel: ObservableObject {
    @Published var club: Club
    @Published var messages: [Message] = []
    @Published var isLoadingMessages = false
    @Published var messageText = ""
    @Published var errorMessage: String?

    init(club: Club) {
        self.club = club
    }

    func load() async {
        isLoadingMessages = true
        do {
            messages = try await APIClient.shared.getMessages(clubId: club.id)
        } catch {
            errorMessage = "Failed to load messages."
        }
        isLoadingMessages = false

        // Connect SignalR and stream new messages in
        ChatService.shared.onMessageReceived = { [weak self] message in
            guard message.clubId == self?.club.id else { return }
            self?.messages.insert(message, at: 0)
        }
        await ChatService.shared.connect(clubId: club.id)
    }

    func sendMessage() async {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        messageText = ""
        await ChatService.shared.sendText(clubId: club.id, body: text)
    }

    func disconnect() async {
        await ChatService.shared.disconnect()
    }
}
