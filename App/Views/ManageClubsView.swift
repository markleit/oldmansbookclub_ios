import SwiftUI

struct ManageClubsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("user_club_id") private var clubIdString: String = ""
    @AppStorage("user_club_name") private var clubName: String = ""

    @State private var clubs: [APIClient.PublicClub] = []
    @State private var currentClub: APIClient.PublicClub?
    @State private var newClubName = ""
    @State private var isLoading = false
    @State private var isCreating = false
    @State private var isLeaving = false
    @State private var confirmJoinClub: APIClient.PublicClub?
    @State private var showLeaveConfirmation = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private var isInClub: Bool { TokenStore.shared.clubId != nil }
    private var currentClubName: String { TokenStore.shared.clubName ?? "Club" }

    var body: some View {
        Form {
            if isInClub {
                currentClubSection
            }
            createSection
            joinSection
            if isInClub {
                leaveSection
            }
        }
        .navigationTitle("Manage Book Clubs")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadClubs() }
        .confirmationDialog(
            "Leave \(currentClubName)?",
            isPresented: $showLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Leave Club", role: .destructive) {
                Task { await leaveClub() }
            }
        } message: {
            Text("You will lose access to this club's books and chat. You can request to rejoin later.")
        }
        .alert("Success", isPresented: Binding(
            get: { successMessage != nil },
            set: { if !$0 { successMessage = nil } }
        )) {
            Button("OK") { successMessage = nil }
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
        .alert("Join Club", isPresented: Binding(
            get: { confirmJoinClub != nil },
            set: { if !$0 { confirmJoinClub = nil } }
        )) {
            Button("Request to Join") {
                if let club = confirmJoinClub {
                    Task { await requestToJoin(club) }
                }
            }
            Button("Cancel", role: .cancel) { confirmJoinClub = nil }
        } message: {
            Text("Request to join \"\(confirmJoinClub?.name ?? "")\"? An admin will review your request.")
        }
    }

    private var currentClubSection: some View {
        Section {
            if let club = currentClub {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(club.name).font(.headline)
                        Text("\(club.memberCount) member\(club.memberCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            } else {
                Text(currentClubName)
                    .font(.headline)
            }
        } header: {
            Text("Current Club")
        }
    }

    private var createSection: some View {
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
    }

    private var joinSection: some View {
        Section {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                let available = clubs.filter { $0.id != TokenStore.shared.clubId }
                if available.isEmpty {
                    Text("No other clubs available.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(available) { club in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(club.name).font(.headline)
                                Text("\(club.memberCount) member\(club.memberCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Request") {
                                confirmJoinClub = club
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        } header: {
            Text("Join an Existing Club")
        }
    }

    private var leaveSection: some View {
        Section {
            Button(role: .destructive) {
                showLeaveConfirmation = true
            } label: {
                if isLeaving {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Leave \(currentClubName)").frame(maxWidth: .infinity)
                }
            }
            .disabled(isLeaving)
        }
    }

    private func loadClubs() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let all = try await APIClient.shared.getPublicClubs()
            clubs = all
            currentClub = all.first { $0.id == TokenStore.shared.clubId }
        } catch {
            errorMessage = "Failed to load clubs."
        }
    }

    private func createClub() async {
        let name = newClubName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            _ = try await APIClient.shared.createClub(name: name, description: nil)
            successMessage = "\"\(name)\" has been created."
            newClubName = ""
            await loadClubs()
        } catch {
            errorMessage = "Could not create club. Please try again."
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

    private func leaveClub() async {
        guard let clubId = TokenStore.shared.clubId else { return }
        isLeaving = true
        defer { isLeaving = false }
        do {
            try await APIClient.shared.leaveClub(clubId: clubId)
            TokenStore.shared.clubId = nil
            TokenStore.shared.clubName = nil
            await loadClubs()
        } catch {
            errorMessage = "Failed to leave club."
        }
    }
}
