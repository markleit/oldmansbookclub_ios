import SwiftUI

struct ClubDetailView: View {
    @StateObject private var viewModel: ClubViewModel

    init(club: Club) {
        _viewModel = StateObject(wrappedValue: ClubViewModel(club: club))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 180)
                    .cornerRadius(8)

                Text(viewModel.club.name)
                    .font(.title)
                    .bold()

                Text(viewModel.club.description)
                    .font(.body)
                    .foregroundColor(.secondary)

                Divider()

                Text("Members & Discussions")
                    .font(.headline)

                Text("(Placeholder — discussions, upcoming events, and members will appear here.)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
        .navigationTitle(viewModel.club.name)
    }
}

struct ClubDetailView_Previews: PreviewProvider {
    static var previews: some View {
        ClubDetailView(club: Club(id: UUID(), name: "Sample Club", description: "A short description."))
    }
}
