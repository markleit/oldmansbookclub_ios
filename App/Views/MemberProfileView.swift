import SwiftUI

struct MemberProfileView: View {
    let member: APIClient.UserResponse
    @State private var avatarImage: UIImage?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                avatarView
                    .padding(.top, 32)

                VStack(spacing: 6) {
                    Text(member.displayName)
                        .font(.title2)
                        .bold()

                    if let nickname = member.nickname, !nickname.isEmpty {
                        Text("\"\(nickname)\"")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    if member.isAdmin {
                        Label("Club Admin", systemImage: "person.badge.key.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    }
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(member.displayName)
        .navigationBarTitleDisplayMode(.inline)
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
                            .font(.system(size: 40))
                            .foregroundColor(.white)
                    )
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(Circle())
    }

    private func loadAvatar() async {
        guard let urlStr = member.avatarUrl, let url = URL(string: urlStr) else { return }
        if let cached = await ImageCache.shared.get(url) { avatarImage = cached; return }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let img = UIImage(data: data) else { return }
        ImageCache.shared[url] = img
        avatarImage = img
    }
}
