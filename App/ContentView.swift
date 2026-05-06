import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                LibraryView()
                    .tag(0)
                    .toolbar(.hidden, for: .tabBar)

                ProfileView()
                    .tag(1)
                    .toolbar(.hidden, for: .tabBar)
            }

            CompactTabBar(selectedTab: $selectedTab)
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

private struct CompactTabBar: View {
    @Binding var selectedTab: Int

    private let items: [(label: String, icon: String)] = [
        ("Library", "books.vertical.fill"),
        ("Profile", "person.crop.circle")
    ]

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { i in
                    Button {
                        selectedTab = i
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: items[i].icon)
                                .font(.system(size: 18))
                            Text(items[i].label)
                                .font(.system(size: 9))
                        }
                        .foregroundColor(selectedTab == i ? .accentColor : Color(.systemGray))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 5)
                        .padding(.bottom, 2)
                    }
                }
            }
            .background(Color(.systemBackground))
            .padding(.bottom, safeAreaBottom * 0.5)
        }
    }

    private var safeAreaBottom: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.bottom ?? 0
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AuthViewModel())
    }
}
