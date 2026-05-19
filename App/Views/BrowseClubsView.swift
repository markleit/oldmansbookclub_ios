import SwiftUI

struct BrowseClubsView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var clubs: [APIClient.PublicClub] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var confirmClub: APIClient.PublicClub?

    var body: some View {
        Group {
            if isLoading && clubs.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if clubs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No clubs found")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(clubs) { club in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(club.name).font(.headline)
                            Text("\(club.memberCount) member\(club.memberCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Request") {
                            confirmClub = club
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Browse Clubs")
        .task { await loadClubs() }
        .alert("Request to Join", isPresented: Binding(
            get: { confirmClub != nil },
            set: { if !$0 { confirmClub = nil } }
        )) {
            Button("Request") {
                if let club = confirmClub {
                    auth.requestToJoin(clubId: club.id)
                }
                confirmClub = nil
            }
            Button("Cancel", role: .cancel) { confirmClub = nil }
        } message: {
            if let club = confirmClub {
                Text("Send a request to join \"\(club.name)\"? The club admin will need to approve it.")
            }
        }
        .overlay {
            if let error = errorMessage {
                VStack {
                    Spacer()
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding()
                }
            }
        }
    }

    private func loadClubs() async {
        isLoading = true
        defer { isLoading = false }
        do {
            clubs = try await APIClient.shared.getPublicClubs()
        } catch {
            errorMessage = "Could not load clubs."
        }
    }
}
