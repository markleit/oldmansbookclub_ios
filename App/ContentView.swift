import SwiftUI

struct ContentView: View {
    @AppStorage("user_is_admin") private var isAdmin = false
    @AppStorage("user_is_club_admin") private var isClubAdmin = false
    @ObservedObject private var deepLink = DeepLinkCoordinator.shared
    @State private var selectedTab = 0
    @State private var profilePath = NavigationPath()

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "books.vertical.fill")
                }
                .tag(0)

            ProfileView(path: $profilePath)
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
                .tag(1)

            MembersView()
                .tabItem {
                    Label("Members", systemImage: "person.2.fill")
                }
                .tag(2)

            if isAdmin || isClubAdmin {
                AdminView()
                    .tabItem {
                        Label(isAdmin ? "Admin" : "Requests", systemImage: isAdmin ? "person.badge.key.fill" : "tray.full")
                    }
                    .tag(3)
            }
        }
        .onChange(of: selectedTab) { tab in
            if tab == 1 { profilePath = NavigationPath() }
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
