import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var auth: AuthViewModel

    private var displayName: String {
        TokenStore.shared.displayName ?? "Book Club Member"
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 96, height: 96)

                Text(displayName).font(.title3).bold()

                Spacer()

                Button(role: .destructive) {
                    auth.signOut()
                } label: {
                    Text("Sign Out")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle("Profile")
        }
    }
}

struct ProfileView_Previews: PreviewProvider {
    static var previews: some View {
        ProfileView()
            .environmentObject(AuthViewModel())
    }
}
