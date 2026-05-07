import SwiftUI

struct LibraryView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @State private var showingAddBook = false
    @State private var bookListExpanded = true
    @State private var pastReadsExpanded = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    if let error = viewModel.errorMessage {
                        VStack(spacing: 12) {
                            Text(error).foregroundColor(.secondary)
                            Button("Retry") { Task { await viewModel.load() } }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }

                    // Currently Reading
                    if !viewModel.currentReads.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "CURRENTLY READING")
                            ForEach(viewModel.currentReads) { book in
                                NavigationLink(destination: BookDetailView(book: book, onDeleted: { viewModel.bookDeleted(book) }, onStatusChanged: { viewModel.bookStatusChanged(book, status: $0) })) {
                                    CurrentBookCard(book: book)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal)
                            }
                        }
                    }

                    // Book List — collapsible
                    if !viewModel.bookList.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            CollapsibleSectionHeader(title: "BOOK LIST", isExpanded: $bookListExpanded)
                            if bookListExpanded {
                                ForEach(viewModel.bookList) { book in
                                    NavigationLink(destination: BookDetailView(book: book, onDeleted: { viewModel.bookDeleted(book) }, onStatusChanged: { viewModel.bookStatusChanged(book, status: $0) })) {
                                        PastBookRow(book: book)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal)
                                    Divider().padding(.leading)
                                }
                            }
                        }
                    }

                    // Past Reads — collapsible
                    if !viewModel.pastReads.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            CollapsibleSectionHeader(title: "PAST READS", isExpanded: $pastReadsExpanded)
                            if pastReadsExpanded {
                                ForEach(viewModel.pastReads) { book in
                                    NavigationLink(destination: BookDetailView(book: book, onDeleted: { viewModel.bookDeleted(book) }, onStatusChanged: { viewModel.bookStatusChanged(book, status: $0) })) {
                                        PastBookRow(book: book)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal)
                                    Divider().padding(.leading)
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
            .refreshable { await viewModel.load() }
            .overlay { if viewModel.isLoading { ProgressView() } }
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
                AddBookSheetWrapper(viewModel: viewModel)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
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
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }
}

struct CurrentBookCard: View {
    let book: Book

    var body: some View {
        HStack(spacing: 16) {
            if let urlStr = book.coverBlobUrl, let url = URL(string: urlStr) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.3))
                }
                .frame(width: 80, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 80, height: 120)
            }

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
            if let urlStr = book.coverBlobUrl, let url = URL(string: urlStr) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.3))
                }
                .frame(width: 36, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 36, height: 52)
            }

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
                        Button("Retry") { Task { await viewModel.load() } }
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
