import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @State private var showingCreateClub = false

    var body: some View {
        NavigationView {
            Group {
                if viewModel.isLoading {
                    ProgressView()
                } else if let error = viewModel.errorMessage {
                    Text(error).foregroundColor(.secondary)
                } else if viewModel.clubs.isEmpty {
                    Text("No clubs yet. Create one to get started.")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
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
                                    if let desc = club.description {
                                        Text(desc)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            .navigationTitle("Clubs")
            .task { await viewModel.load() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingCreateClub = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingCreateClub) {
                CreateClubView { club in viewModel.clubCreated(club) }
            }
        }
    }
}

struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
    }
}
