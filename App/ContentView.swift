import SwiftUI

struct ContentView: View {
    @AppStorage("user_is_admin") private var isAdmin = false
    @ObservedObject private var deepLink = DeepLinkCoordinator.shared
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "books.vertical.fill")
                }
                .tag(0)

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
                .tag(1)

            MembersView()
                .tabItem {
                    Label("Members", systemImage: "person.2.fill")
                }
                .tag(2)

            if isAdmin {
                AdminView()
                    .tabItem {
                        Label("Admin", systemImage: "person.badge.key.fill")
                    }
                    .tag(3)
            }
        }
        .onChange(of: deepLink.pendingBookId) { bookId in
            if bookId != nil { selectedTab = 0 }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AuthViewModel())
    }
}
