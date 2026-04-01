import Foundation

@MainActor
final class EventsViewModel: ObservableObject {
    @Published var events: [Event] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            events = try await APIClient.shared.getMyEvents()
        } catch {
            errorMessage = "Failed to load events."
        }
        isLoading = false
    }
}
