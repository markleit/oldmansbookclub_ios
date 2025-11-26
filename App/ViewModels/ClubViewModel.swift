import Foundation

final class ClubViewModel: ObservableObject {
    @Published var club: Club

    init(club: Club) {
        self.club = club
    }
}
