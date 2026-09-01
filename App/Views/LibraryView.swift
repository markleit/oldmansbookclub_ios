import SwiftUI

struct LibraryView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @ObservedObject private var deepLink = DeepLinkCoordinator.shared
    @State private var showingAddBook = false
    @State private var showingReorderFutureReads = false
    @State private var bookListExpanded = true
    @State private var pastReadsExpanded = true
    @State private var navigationPath = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                if viewModel.isOffline {
                    Label("Offline — showing cached library", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color(.systemGray6))
                }
                ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    if let error = viewModel.errorMessage {
                        VStack(spacing: 12) {
                            Text(error).foregroundColor(.secondary)
                            Button("Retry") { Task { await viewModel.load(force: true) } }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }

                    // Currently Reading
                    if !viewModel.currentReads.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "CURRENTLY READING")
                            ForEach(viewModel.currentReads) { book in
                                NavigationLink(value: book) {
                                    CurrentBookCard(book: book, refreshToken: viewModel.imageRefreshToken)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal)
                            }
                        }
                    }

                    // Future Reads — collapsible
                    if !viewModel.bookList.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            CollapsibleSectionHeader(title: "FUTURE READS", isExpanded: $bookListExpanded)
                            if bookListExpanded {
                                ForEach(viewModel.futureReadGroups) { item in
                                    ReadItemRow(item: item, refreshToken: viewModel.imageRefreshToken)
                                }
                            }
                        }
                    }

                    // Past Reads — collapsible
                    if !viewModel.pastReads.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            CollapsibleSectionHeader(title: "PAST READS", isExpanded: $pastReadsExpanded)
                            if pastReadsExpanded {
                                ForEach(viewModel.pastReadGroups) { item in
                                    ReadItemRow(item: item, refreshToken: viewModel.imageRefreshToken)
                                }
                            }
                        }
                    }

                    if viewModel.books.isEmpty && viewModel.errorMessage == nil && !viewModel.isLoading {
                        Text("No books yet. Add one to get started.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
}
                .padding(.vertical)
            }
            .refreshable { await viewModel.load(force: true) }
            .overlay { if viewModel.isLoading { ProgressView() } }
            .navigationTitle(viewModel.clubName ?? "Library")
            .navigationDestination(for: Book.self) { book in
                BookDetailView(
                    book: book,
                    onDeleted: { viewModel.bookDeleted(book) },
                    onStatusChanged: { viewModel.bookStatusChanged(book, status: $0) },
                    onUpdated: { viewModel.bookUpdated($0) }
                )
                // Distinct identity per book so a deep link that swaps one book for
                // another at the same stack depth rebuilds the view (and its
                // @StateObject BookViewModel) instead of reusing the stale one (#49).
                .id(book.id)
            }
            .task {
                await viewModel.load()
                navigateToPendingBook()
            }
            .onChange(of: scenePhase) { phase in
                // Refresh on foreground so unread counts + the app badge reflect
                // anything read elsewhere / arrived while backgrounded.
                if phase == .active { Task { await viewModel.load() } }
            }
            .onChange(of: deepLink.pendingBookId) { _ in
                navigateToPendingBook()
            }
            .onChange(of: viewModel.books) { _ in
                navigateToPendingBook()
            }
            .toolbar {
                if viewModel.myClubs.count > 1 {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Menu {
                            ForEach(viewModel.myClubs) { club in
                                Button {
                                    viewModel.switchClub(club)
                                } label: {
                                    if club.id == viewModel.clubId {
                                        Label(club.name, systemImage: "checkmark")
                                    } else {
                                        Text(club.name)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.left.arrow.right.circle")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        addBookButton
                        // #137 — reordering is club-admin only; a regular member wouldn't see a
                        // control they can't use.
                        if canReorderFutureReads {
                            reorderFutureReadsButton
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("libraryMenuButton")
                }
            }
            .sheet(isPresented: $showingAddBook) {
                AddBookSheetWrapper(viewModel: viewModel)
            }
            .sheet(isPresented: $showingReorderFutureReads) {
                FutureReadOrderView(viewModel: viewModel)
            }
            } // VStack
        }
    }

    private var canReorderFutureReads: Bool {
        TokenStore.shared.isClubAdmin && !viewModel.bookList.isEmpty
    }

    private var addBookButton: some View {
        Button { showingAddBook = true } label: {
            Label("Add Book", systemImage: "plus")
        }
    }

    private var reorderFutureReadsButton: some View {
        Button { showingReorderFutureReads = true } label: {
            Label("Manage Future Read Order", systemImage: "arrow.up.arrow.down")
        }
    }

    private func navigateToPendingBook() {
        guard let bookId = deepLink.pendingBookId,
              let book = viewModel.books.first(where: { $0.id == bookId }) else { return }
        deepLink.pendingBookId = nil
        // Make the book's club active first so Back lands on the right library (#57).
        viewModel.setActiveClub(book.clubId)
        var newPath = NavigationPath()
        newPath.append(book)
        navigationPath = newPath
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.primary.opacity(0.7))   // darker than .secondary, still lighter than titles
            .padding(.horizontal)
    }
}

struct CollapsibleSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool
    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary.opacity(0.7))   // darker than .secondary
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.primary.opacity(0.7))
            }
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }
}

// Red unread-count pill, overlaid on a book cover. Hidden when zero.
struct UnreadBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2.weight(.bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red, in: Capsule())
                .overlay(Capsule().stroke(Color(.systemBackground), lineWidth: 1.5))
                .offset(x: 8, y: -6)
        }
    }
}

struct CurrentBookCard: View {
    let book: Book
    var refreshToken: UUID = UUID()
    @ObservedObject private var unreadStore = UnreadStore.shared

    var body: some View {
        HStack(spacing: 16) {
            CachedBookCover(urlString: book.coverBlobUrl, width: 80, height: 120, cornerRadius: 8, refreshToken: refreshToken)
                .overlay(alignment: .topTrailing) { UnreadBadge(count: unreadStore.counts[book.id] ?? 0) }

            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.title3)
                    .bold()
                    .foregroundColor(.primary)
                Text(book.author)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Label("Discussion", systemImage: "bubble.left.and.bubble.right")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
            Spacer()
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

// #138 — renders one Future/Past Reads entry: a standalone book (unchanged from before), or a
// series as a small header followed by its members, each still an individually-tappable row.
struct ReadItemRow: View {
    let item: ReadItem
    var refreshToken: UUID = UUID()

    var body: some View {
        switch item {
        case .single(let book):
            NavigationLink(value: book) {
                PastBookRow(book: book, refreshToken: refreshToken)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            Divider().padding(.leading)

        case .series(let name, let books):
            VStack(alignment: .leading, spacing: 2) {
                // Deliberately NOT styled like SectionHeader/CollapsibleSectionHeader (caption,
                // semibold, all-caps) — a series is a sub-grouping WITHIN Future/Past Reads, not
                // another top-level section, and the two read as the same kind of thing at a
                // glance if they share that treatment. Regular weight + lighter color + title
                // case (not all-caps) + an icon makes the hierarchy unambiguous.
                Label {
                    Text("\(name) · \(books.count) book\(books.count == 1 ? "" : "s")")
                        .font(.caption2)
                } icon: {
                    Image(systemName: "books.vertical")
                        .font(.caption2)
                }
                // Darker than plain .tertiary, but still visibly lighter than the section
                // headers' 0.7 above it — keeps the hierarchy (section > series > book) legible.
                .foregroundStyle(.primary.opacity(0.55))
                .padding(.horizontal)
                .padding(.top, 6)
                ForEach(books) { book in
                    NavigationLink(value: book) {
                        PastBookRow(book: book, refreshToken: refreshToken)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 28)
                    .padding(.trailing)
                    Divider().padding(.leading, 28)
                }
            }
        }
    }
}

struct PastBookRow: View {
    let book: Book
    var refreshToken: UUID = UUID()
    @ObservedObject private var unreadStore = UnreadStore.shared

    var body: some View {
        HStack(spacing: 12) {
            CachedBookCover(urlString: book.coverBlobUrl, width: 36, height: 52, cornerRadius: 4, refreshToken: refreshToken)
                .overlay(alignment: .topTrailing) { UnreadBadge(count: unreadStore.counts[book.id] ?? 0) }

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.headline).foregroundColor(.primary)
                Text(book.author).font(.subheadline).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct AddBookSheetWrapper: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        if let clubId = viewModel.clubId {
            AddBookView(clubId: clubId) { book in viewModel.bookCreated(book) }
        } else {
            NavigationStack {
                VStack(spacing: 16) {
                    if viewModel.isLoading {
                        ProgressView("Loading…")
                    } else {
                        Text("Couldn't load club info.")
                            .foregroundColor(.secondary)
                        Button("Retry") { Task { await viewModel.load(force: true) } }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Add Book")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .task { await viewModel.load() }
            }
        }
    }
}

struct LibraryView_Previews: PreviewProvider {
    static var previews: some View {
        LibraryView()
    }
}
