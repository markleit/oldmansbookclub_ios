import Foundation

@MainActor
final class MembersViewModel: ObservableObject {
    @Published var members: [APIClient.UserResponse] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            members = try await APIClient.shared.getMembers()
        } catch {
            errorMessage = "Failed to load members."
        }
    }
}
