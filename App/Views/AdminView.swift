import SwiftUI

struct AdminView: View {
    @State private var pendingUsers: [APIClient.PendingUser] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
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
                                Text(user.displayName)
                                    .font(.headline)
                                if let email = user.email {
                                    Text(email)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text(user.createdAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
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
            .navigationTitle("Pending Approvals")
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

    private func load() async {
        isLoading = pendingUsers.isEmpty
        defer { isLoading = false }
        do {
            pendingUsers = try await APIClient.shared.pendingUsers()
        } catch {
            errorMessage = "Failed to load pending users."
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
}
