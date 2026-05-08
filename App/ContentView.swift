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
