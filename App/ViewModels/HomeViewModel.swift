import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var clubs: [Club] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            clubs = try await APIClient.shared.getMyClubs()
        } catch {
            errorMessage = "Failed to load clubs."
        }
        isLoading = false
    }

    func clubCreated(_ club: Club) {
        clubs.append(club)
    }
}
