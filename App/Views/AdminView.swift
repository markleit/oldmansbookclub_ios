import SwiftUI

struct AdminView: View {
    @State private var selectedTab = 0
    @State private var pendingUsers: [APIClient.PendingUser] = []
    @State private var members: [APIClient.UserResponse] = []
    @State private var reports: [APIClient.AdminReport] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var myId: UUID? { TokenStore.shared.userId }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("Pending").tag(0)
                    Text("Members").tag(1)
                    Text("Reports").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedTab == 0 {
                    pendingView
                } else if selectedTab == 1 {
                    membersView
                } else {
                    reportsView
                }
            }
            .navigationTitle("Admin")
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

    // MARK: - Pending

    private var pendingView: some View {
        Group {
            if isLoading && pendingUsers.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pendingUsers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No pending approvals")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(pendingUsers) { user in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName).font(.headline)
                            if let email = user.email {
                                Text(email).font(.caption).foregroundColor(.secondary)
                            }
                            Text(user.createdAt, style: .relative)
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Approve") {
                            Task { await approve(user.id) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Members

    private var membersView: some View {
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
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.displayName).font(.headline)
                                if let nick = member.nickname {
                                    Text("\"\(nick)\"").font(.caption).foregroundColor(.secondary)
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
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if member.id != myId {
                                Button(role: .destructive) {
                                    Task { await deleteUser(member.id) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    Task { await setRole(member.id, isAdmin: !member.isAdmin) }
                                } label: {
                                    Label(member.isAdmin ? "Remove Admin" : "Make Admin",
                                          systemImage: member.isAdmin ? "person.fill.xmark" : "person.badge.key.fill")
                                }
                                .tint(member.isAdmin ? .orange : .blue)
                            }
                        }
                    }
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

    // MARK: - Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        async let pending = APIClient.shared.pendingUsers()
        async let approved = APIClient.shared.getMembers()
        async let reportList = APIClient.shared.getReports()
        do {
            (pendingUsers, members, reports) = try await (pending, approved, reportList)
        } catch {
            errorMessage = "Failed to load."
        }
    }

    private func approve(_ id: UUID) async {
        do {
            try await APIClient.shared.approveUser(id: id)
            pendingUsers.removeAll { $0.id == id }
        } catch {
            errorMessage = "Failed to approve user."
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

    private func setRole(_ id: UUID, isAdmin: Bool) async {
        do {
            try await APIClient.shared.setUserRole(id: id, isAdmin: isAdmin)
            if let idx = members.firstIndex(where: { $0.id == id }) {
                let m = members[idx]
                members[idx] = APIClient.UserResponse(
                    id: m.id, displayName: m.displayName,
                    nickname: m.nickname, avatarUrl: m.avatarUrl,
                    isAdmin: isAdmin)
            }
            if id == myId {
                TokenStore.shared.isAdmin = isAdmin
            }
        } catch {
            errorMessage = "Failed to update role."
        }
    }
}
