import Foundation

final class HomeViewModel: ObservableObject {
    @Published var clubs: [Club] = []

    init() {
        // Sample data for the scaffold
        clubs = [
            Club(id: UUID(), name: "Evening Readers", description: "A cozy group for evening reading and discussion."),
            Club(id: UUID(), name: "Sci-Fi Fans", description: "We read one sci-fi book per month."),
            Club(id: UUID(), name: "Local Authors", description: "Spotlight on authors from our region.")
        ]
    }
}
