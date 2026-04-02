import SwiftUI

struct LibraryView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @State private var showingAddBook = false

    var body: some View {
        NavigationView {
            Group {
                if viewModel.isLoading {
                    ProgressView()
                } else if let error = viewModel.errorMessage {
                    Text(error).foregroundColor(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            // Currently reading
                            if let current = viewModel.currentRead {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("CURRENTLY READING")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal)

                                    NavigationLink(destination: BookDetailView(book: current)) {
                                        CurrentBookCard(book: current)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal)
                                }
                            }

                            // Past reads
                            if !viewModel.pastReads.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("PAST READS")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal)

                                    ForEach(viewModel.pastReads) { book in
                                        NavigationLink(destination: BookDetailView(book: book)) {
                                            PastBookRow(book: book)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.horizontal)

                                        Divider().padding(.leading)
                                    }
                                }
                            }

                            if viewModel.books.isEmpty {
                                Text("No books yet. Add one to get started.")
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 60)
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationTitle("Library")
            .task { await viewModel.load() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAddBook = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddBook) {
                if let clubId = TokenStore.shared.clubId {
                    AddBookView(clubId: clubId) { book in viewModel.bookCreated(book) }
                }
            }
        }
    }
}

struct CurrentBookCard: View {
    let book: Book

    var body: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 80, height: 120)

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

struct PastBookRow: View {
    let book: Book

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 36, height: 52)

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

struct LibraryView_Previews: PreviewProvider {
    static var previews: some View {
        LibraryView()
    }
}
