import SwiftUI

struct ProfileView: View {
    // Sample user
    private let user = User(id: UUID(), name: "Demo User", email: "demo@example.com")

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 96, height: 96)

                Text(user.name).font(.title3).bold()
                if let email = user.email {
                    Text(email).font(.subheadline).foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Profile")
        }
    }
}

struct ProfileView_Previews: PreviewProvider {
    static var previews: some View {
        ProfileView()
    }
}
