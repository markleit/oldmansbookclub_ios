import SwiftUI

struct JoinOrCreateClubView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var clubs: [APIClient.PublicClub] = []
    @State private var myClubIds: Set<UUID> = []
    @State private var newClubName = ""
    @State private var isLoading = false
    @State private var isCreating = false
    @State private var successMessage: String?
    @State private var errorMessage: String?
    @State private var confirmClub: APIClient.PublicClub?

    var onClubCreated: ((Club) -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Club name", text: $newClubName)
                        .autocorrectionDisabled()
                    Button {
                        Task { await createClub() }
                    } label: {
                        if isCreating {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Create Club").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(newClubName.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
                } header: {
                    Text("Start a New Club")
                }

                Section {
                    if isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if clubs.filter({ !myClubIds.contains($0.id) }).isEmpty {
                        Text("No other clubs available.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(clubs.filter { !myClubIds.contains($0.id) }) { club in
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
                        }
                    }
                } header: {
                    Text("Join an Existing Club")
                }
            }
            .navigationTitle("Clubs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .alert("Join Club", isPresented: Binding(
                get: { confirmClub != nil },
                set: { if !$0 { confirmClub = nil } }
            )) {
                Button("Request to Join") {
                    if let club = confirmClub {
                        Task { await requestToJoin(club) }
                    }
                }
                Button("Cancel", role: .cancel) { confirmClub = nil }
            } message: {
                Text("Request to join \"\(confirmClub?.name ?? "")\"? An admin will review your request.")
            }
            .alert("Success", isPresented: Binding(
                get: { successMessage != nil },
                set: { if !$0 { successMessage = nil } }
            )) {
                Button("OK") { dismiss() }
            } message: {
                Text(successMessage ?? "")
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await loadClubs() }
        }
    }

    private func loadClubs() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let publicClubs = APIClient.shared.getPublicClubs()
            async let myClubs = APIClient.shared.getMyClubs()
            let (all, mine) = try await (publicClubs, myClubs)
            myClubIds = Set(mine.map(\.id))
            clubs = all
        } catch {
            errorMessage = "Failed to load clubs."
        }
    }

    private func requestToJoin(_ club: APIClient.PublicClub) async {
        do {
            try await APIClient.shared.requestToJoinClub(clubId: club.id)
            successMessage = "Your request to join \"\(club.name)\" has been submitted. You'll gain access once an admin approves it."
        } catch {
            errorMessage = "Could not submit request. You may already be a member or have a pending request."
        }
    }

    private func createClub() async {
        let name = newClubName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let club = try await APIClient.shared.createClub(name: name, description: nil)
            onClubCreated?(club)
            dismiss()
        } catch {
            errorMessage = "Could not create club. Please try again."
        }
    }
}
