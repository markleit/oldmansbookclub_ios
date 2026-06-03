import SwiftUI

struct ManageClubsView: View {
    @AppStorage("club_id") private var storedClubId: String = ""
    @AppStorage("club_name") private var storedClubName: String = ""

    @State private var publicClubs: [APIClient.PublicClub] = []
    @State private var myClubIds: Set<UUID> = []
    @State private var newClubName = ""
    @State private var isLoading = false
    @State private var isCreating = false
    @State private var isLeaving = false
    @State private var clubToJoin: APIClient.PublicClub?
    @State private var clubToLeave: APIClient.PublicClub?
    @State private var alertMessage: String?

    private var activeClubId: UUID? { TokenStore.shared.clubId }
    private var currentClubName: String { storedClubName.isEmpty ? "Club" : storedClubName }

    private func status(of club: APIClient.PublicClub) -> ClubStatus {
        if club.id == activeClubId { return .active }
        if myClubIds.contains(club.id) { return .member }
        return .notMember
    }

    private var sortedClubs: [APIClient.PublicClub] {
        publicClubs.sorted { a, b in
            status(of: a).sortOrder < status(of: b).sortOrder
        }
    }

    var body: some View {
        Form {
            clubListSection
            createSection
        }
        .navigationTitle("Manage Book Clubs")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadClubs() }
        .confirmationDialog(
            "Leave \(clubToLeave?.name ?? currentClubName)?",
            isPresented: Binding(get: { clubToLeave != nil }, set: { if !$0 { clubToLeave = nil } }),
            titleVisibility: .visible
        ) {
            Button("Leave Club", role: .destructive) {
                Task { await leaveClub() }
            }
        } message: {
            Text("You will lose access to this club's books and chat. You can request to rejoin later.")
        }
        .confirmationDialog(
            "Request to Join",
            isPresented: Binding(get: { clubToJoin != nil }, set: { if !$0 { clubToJoin = nil } }),
            titleVisibility: .visible
        ) {
            Button("Send Request") {
                if let club = clubToJoin { Task { await requestToJoin(club) } }
            }
            Button("Cancel", role: .cancel) { clubToJoin = nil }
        } message: {
            Text("Send a request to join \"\(clubToJoin?.name ?? "")\"? An admin will review it.")
        }
        .alert("Notice", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var clubListSection: some View {
        Section {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if sortedClubs.isEmpty {
                Text("No clubs available.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(sortedClubs) { club in
                    let s = status(of: club)
                    HStack(spacing: 12) {
                        Image(systemName: s == .active ? "checkmark.circle.fill" : "checkmark.circle")
                            .foregroundColor(s == .active ? .green : Color(.systemGray3))
                            .font(.system(size: 20))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(club.name).font(.headline)
                            Text("\(club.memberCount) member\(club.memberCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if s == .active {
                            Button("Leave") { clubToLeave = club }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.red)
                                .disabled(isLeaving)
                        } else if s == .notMember {
                            Button("Request") { clubToJoin = club }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }
        } header: {
            Text("Book Clubs")
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

    private func loadClubs() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let publicFetch = APIClient.shared.getPublicClubs()
            async let myFetch = APIClient.shared.getMyClubs()
            let (all, mine) = try await (publicFetch, myFetch)
            publicClubs = all
            myClubIds = Set(mine.map(\.id))
        } catch {
            alertMessage = "Failed to load clubs."
        }
    }

    private func createClub() async {
        let name = newClubName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            _ = try await APIClient.shared.createClub(name: name, description: nil)
            newClubName = ""
            alertMessage = "\"\(name)\" has been created."
            await loadClubs()
        } catch {
            alertMessage = "Could not create club. Please try again."
        }
    }

    private func requestToJoin(_ club: APIClient.PublicClub) async {
        clubToJoin = nil
        do {
            try await APIClient.shared.requestToJoinClub(clubId: club.id)
            alertMessage = "Your request to join \"\(club.name)\" has been submitted. An admin will review it."
        } catch {
            alertMessage = "Could not submit request. You may already be a member or have a pending request."
        }
    }

    private func leaveClub() async {
        guard let clubId = TokenStore.shared.clubId else { return }
        isLeaving = true
        clubToLeave = nil
        defer { isLeaving = false }
        do {
            try await APIClient.shared.leaveClub(clubId: clubId)
            TokenStore.shared.clubId = nil
            TokenStore.shared.clubName = nil
            await loadClubs()
        } catch {
            alertMessage = "Failed to leave club."
        }
    }
}

private enum ClubStatus {
    case active, member, notMember
    var sortOrder: Int {
        switch self {
        case .active: return 0
        case .member: return 1
        case .notMember: return 2
        }
    }
}
