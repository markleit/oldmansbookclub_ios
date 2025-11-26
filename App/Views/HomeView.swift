import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()

    var body: some View {
        NavigationView {
            List(viewModel.clubs) { club in
                NavigationLink(destination: ClubDetailView(club: club)) {
                    HStack(alignment: .top, spacing: 12) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.4))
                            .frame(width: 50, height: 70)
                            .cornerRadius(6)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(club.name)
                                .font(.headline)
                            Text(club.description)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("Clubs")
        }
    }
}

struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
    }
}
