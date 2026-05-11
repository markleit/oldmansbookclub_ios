import SwiftUI

struct MembersView: View {
    @StateObject private var viewModel = MembersViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.members.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    List(viewModel.members, id: \.id) { member in
                        NavigationLink(destination: MemberProfileView(member: member)) {
                            MemberRow(member: member)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Members")
            .task { await viewModel.load() }
            .refreshable { await viewModel.load() }
        }
    }
}

private struct MemberRow: View {
    let member: APIClient.UserResponse
    @State private var avatarImage: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            avatarView

            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName)
                    .font(.body)

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
