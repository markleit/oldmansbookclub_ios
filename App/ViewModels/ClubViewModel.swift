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

    func loadMessages() async {
        isLoadingMessages = true
        do {
            messages = try await APIClient.shared.getMessages(clubId: club.id)
        } catch {
            errorMessage = "Failed to load messages."
        }
        isLoadingMessages = false
    }
}
