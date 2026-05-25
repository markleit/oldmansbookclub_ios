import SwiftUI

struct AdminView: View {
    @State private var selectedTab = 0
    @State private var joinRequests: [APIClient.JoinRequest] = []
    @State private var members: [APIClient.UserResponse] = []
    @State private var reports: [APIClient.AdminReport] = []
    @State private var myClubs: [Club] = []
    @State private var selectedClubId: UUID? = nil
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var myId: UUID? { TokenStore.shared.userId }
    private var isGlobalAdmin: Bool { TokenStore.shared.isAdmin }

    // Falls back to TokenStore before clubs load to avoid picker flicker on first render
    private var isAnyClubAdmin: Bool {
        myClubs.isEmpty ? TokenStore.shared.isClubAdmin : myClubs.contains { $0.isClubAdmin }
    }
    private var showAdminTabs: Bool { isGlobalAdmin || isAnyClubAdmin }

    private var isClubAdminOfSelected: Bool {
        guard let id = selectedClubId else { return false }
        return myClubs.first { $0.id == id }?.isClubAdmin ?? false
    }

    private var navigationTitle: String {
        isGlobalAdmin ? "Admin" : isAnyClubAdmin ? "Club Admin" : "Members"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showAdminTabs {
                    Picker("", selection: $selectedTab) {
                        Text("Requests").tag(0)
                        Text("Members").tag(1)
                        if isGlobalAdmin {
                            Text("Reports").tag(2)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding()
                }

                if showAdminTabs && selectedTab == 0 {
                    requestsView
                } else if !showAdminTabs || selectedTab == 1 {
                    membersView
                } else {
                    reportsView
                }
            }
            .navigationTitle(navigationTitle)
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    // MARK: - Requests

    private var requestsView: some View {
        Group {
            if isLoading && joinRequests.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if joinRequests.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No pending requests")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(joinRequests) { request in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(request.displayName).font(.headline)
                            Text(request.clubName)
                                .font(.subheadline)
                                .foregroundColor(.accentColor)
                            if let email = request.email {
                                Text(email).font(.caption).foregroundColor(.secondary)
                            }
                            Text(request.createdAt, style: .relative)
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(spacing: 6) {
                            Button("Approve") {
                                Task { await approveRequest(request.id) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Button("Decline") {
                                Task { await declineRequest(request.id) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.red)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Members

    private var membersView: some View {
        VStack(spacing: 0) {
            if isGlobalAdmin || myClubs.count > 1 {
                Picker("Club", selection: $selectedClubId) {
                    if isGlobalAdmin {
                        Text("All Clubs").tag(UUID?.none)
                    }
                    ForEach(myClubs) { club in
                        Text(club.name).tag(UUID?.some(club.id))
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .onChange(of: selectedClubId) { _ in
                    Task { await loadMembers() }
                }
                Divider()
            }
            Group {
                if isLoading && members.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if members.isEmpty {
                    Text("No members yet.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(members, id: \.id) { member in
                            NavigationLink(destination: MemberProfileView(member: member)) {
                                MemberRow(member: member)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if member.id != myId {
                                    if let clubId = selectedClubId,
                                       isGlobalAdmin || isClubAdminOfSelected {
                                        Button {
                                            Task { await removeMember(member.id, from: clubId) }
                                        } label: {
                                            Label("Kick", systemImage: "person.badge.minus")
                                        }
                                        .tint(.orange)
                                    }
                                    if isGlobalAdmin {
                                        if let clubId = selectedClubId {
                                            Button {
                                                Task { await setClubAdmin(member.id, clubId: clubId, isClubAdmin: !member.isClubAdmin) }
                                            } label: {
                                                Label(
                                                    member.isClubAdmin ? "Revoke Club Admin" : "Make Club Admin",
                                                    systemImage: member.isClubAdmin ? "person.fill.badge.minus" : "person.fill.badge.plus"
                                                )
                                            }
                                            .tint(member.isClubAdmin ? .indigo : .teal)
                                        }
                                        Button {
                                            Task { await setRole(member.id, isAdmin: !member.isAdmin) }
                                        } label: {
                                            Label(
                                                member.isAdmin ? "Demote" : "Make Admin",
                                                systemImage: member.isAdmin ? "key.slash" : "person.badge.key.fill"
                                            )
                                        }
                                        .tint(member.isAdmin ? .indigo : .blue)
                                        Button(role: .destructive) {
                                            Task { await deleteUser(member.id) }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
    }

    // MARK: - Reports

    private var reportsView: some View {
        Group {
            if isLoading && reports.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if reports.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "flag.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No reports")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(reports) { report in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(report.senderName).font(.headline)
                            Spacer()
                            Text(report.reportedAt, style: .relative)
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        if let body = report.messageBody {
                            Text(body)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        } else {
                            Text("[\(report.messageType.rawValue.lowercased()) message]")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                        Text("Reported by \(report.reporterName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await dismissReport(report) }
                        } label: {
                            Label("Dismiss", systemImage: "checkmark")
                        }
                        .tint(.green)
                    }
                }
            }
        }
    }

    // MARK: - Data

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let isAdmin = TokenStore.shared.isAdmin

            // Fetch clubs first so we know actual admin status before deciding what else to fetch
            myClubs = try await APIClient.shared.getMyClubs()

            let actualIsClubAdmin = myClubs.contains { $0.isClubAdmin }
            if TokenStore.shared.isClubAdmin != actualIsClubAdmin {
                TokenStore.shared.isClubAdmin = actualIsClubAdmin
            }

            if selectedClubId == nil {
                selectedClubId = myClubs.first?.id
            }

            async let membersFetch = APIClient.shared.getMembers(clubId: selectedClubId)
            if isAdmin {
                async let requestsFetch = APIClient.shared.getJoinRequests()
                async let reportsFetch = APIClient.shared.getReports()
                (joinRequests, members, reports) = try await (requestsFetch, membersFetch, reportsFetch)
            } else if actualIsClubAdmin {
                async let requestsFetch = APIClient.shared.getJoinRequests()
                (joinRequests, members) = try await (requestsFetch, membersFetch)
            } else {
                members = try await membersFetch
                joinRequests = []
            }
        } catch {
            if !isCancellation(error) { errorMessage = "Failed to load." }
        }
    }

    private func loadMembers() async {
        do {
            members = try await APIClient.shared.getMembers(clubId: selectedClubId)
        } catch {
            if !isCancellation(error) { errorMessage = "Failed to load members." }
        }
    }

    // MARK: - Actions

    private func approveRequest(_ id: UUID) async {
        do {
            try await APIClient.shared.approveJoinRequest(id: id)
            joinRequests.removeAll { $0.id == id }
        } catch {
            errorMessage = "Failed to approve request."
        }
    }

    private func declineRequest(_ id: UUID) async {
        do {
            try await APIClient.shared.declineJoinRequest(id: id)
            joinRequests.removeAll { $0.id == id }
        } catch {
            errorMessage = "Failed to decline request."
        }
    }

    private func removeMember(_ userId: UUID, from clubId: UUID) async {
        do {
            try await APIClient.shared.removeMember(userId: userId, clubId: clubId)
            members.removeAll { $0.id == userId }
        } catch {
            errorMessage = "Failed to remove member."
        }
    }

    private func deleteUser(_ id: UUID) async {
        do {
            try await APIClient.shared.deleteUser(id: id)
            members.removeAll { $0.id == id }
        } catch {
            errorMessage = "Failed to delete user."
        }
    }

    private func dismissReport(_ report: APIClient.AdminReport) async {
        reports.removeAll { $0.id == report.id }
        do {
            try await APIClient.shared.dismissReport(id: report.id)
        } catch {
            reports.append(report)
            errorMessage = "Failed to dismiss report."
        }
    }

    private func setClubAdmin(_ userId: UUID, clubId: UUID, isClubAdmin: Bool) async {
        do {
            try await APIClient.shared.setClubAdmin(userId: userId, clubId: clubId, isClubAdmin: isClubAdmin)
            if let idx = members.firstIndex(where: { $0.id == userId }) {
                let m = members[idx]
                members[idx] = APIClient.UserResponse(
                    id: m.id, displayName: m.displayName,
                    nickname: m.nickname, avatarUrl: m.avatarUrl,
                    isAdmin: m.isAdmin, isClubAdmin: isClubAdmin)
            }
        } catch {
            errorMessage = "Failed to update club admin status."
        }
    }

    private func setRole(_ id: UUID, isAdmin: Bool) async {
        do {
            try await APIClient.shared.setUserRole(id: id, isAdmin: isAdmin)
            if let idx = members.firstIndex(where: { $0.id == id }) {
                let m = members[idx]
                members[idx] = APIClient.UserResponse(
                    id: m.id, displayName: m.displayName,
                    nickname: m.nickname, avatarUrl: m.avatarUrl,
                    isAdmin: isAdmin, isClubAdmin: m.isClubAdmin)
            }
            if id == myId {
                TokenStore.shared.isAdmin = isAdmin
            }
        } catch {
            errorMessage = "Failed to update role."
        }
    }
}

private func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}

// MARK: - Member Row

private struct MemberRow: View {
    let member: APIClient.UserResponse
    @State private var avatarImage: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            avatarView
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName).font(.body)
                if let nickname = member.nickname, !nickname.isEmpty {
                    Text("\"\(nickname)\"")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if member.isAdmin {
                Image(systemName: "person.badge.key.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .task { await loadAvatar() }
    }

    @ViewBuilder
    private var avatarView: some View {
        Group {
            if let image = avatarImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color(.systemGray4))
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                    )
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
    }

    private func loadAvatar() async {
        guard let urlStr = member.avatarUrl, let url = URL(string: urlStr) else { return }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return }
        avatarImage = UIImage(data: data)
    }
}
