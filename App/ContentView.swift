import SwiftUI

struct ContentView: View {
    private var isAdmin: Bool { TokenStore.shared.isAdmin }

    var body: some View {
        TabView {
            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "books.vertical.fill")
                }

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }

            MembersView()
                .tabItem {
                    Label("Members", systemImage: "person.2.fill")
                }

            if isAdmin {
                AdminView()
                    .tabItem {
                        Label("Admin", systemImage: "person.badge.key.fill")
                    }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AuthViewModel())
    }
}
