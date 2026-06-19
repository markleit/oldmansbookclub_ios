import SwiftUI

struct AddBookView: View {
    @Environment(\.dismiss) private var dismiss
    let clubId: UUID
    var onAdded: (Book) -> Void

    @State private var title = ""
    @State private var author = ""
    @State private var coverUrl: String?
    @State private var isSearching = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchResults: [APIClient.BookSearchResult] = []
    @State private var showingPicker = false
    @State private var searchTask: Task<Void, Never>?
    // Set true right before we fill the title from a picked result, so its
    // .onChange doesn't kick off another search and clobber the selection.
    @State private var suppressSearch = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Dune", text: $title)
                        .onChange(of: title) { _ in
                            if suppressSearch { suppressSearch = false; return }
                            scheduleSearch()
                        }
                } header: {
                    Text("Title")
                } footer: {
                    Text("Start typing to search for cover art and author.")
                }

                if isSearching || coverUrl != nil {
                    Section("Cover") {
                        HStack {
                            if isSearching {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 80, height: 120)
                                    .overlay(ProgressView().scaleEffect(0.7))
                            } else if let url = coverUrl, let imageUrl = URL(string: url) {
                                AsyncImage(url: imageUrl) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.gray.opacity(0.2))
                                }
                                .frame(width: 80, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    TextField("Author", text: $author)
                } header: {
                    HStack {
                        Text("Author")
                        Spacer()
                        if !searchResults.isEmpty {
                            Button(searchResults.count > 1 ? "Choose edition" : "Use match") {
                                showingPicker = true
                            }
                            .font(.caption)
                        }
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error).foregroundColor(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("Add Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Button("Add") { Task { await add() } }
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showingPicker) {
                BookPickerSheet(results: searchResults) { result in
                    apply(result)
                    showingPicker = false
                }
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchResults = []
        let t = title.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else {
            author = ""
            coverUrl = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(title: t)
        }
    }

    private func runSearch(title: String) async {
        isSearching = true
        defer { isSearching = false }
        let results = await APIClient.shared.searchBooks(title: title)
        guard !Task.isCancelled else { return }
        searchResults = results
        // Preview author/cover from the top match as you type, but DON'T touch the
        // title — that only changes when you explicitly pick a result below.
        if let first = results.first {
            author = first.author
            coverUrl = first.coverUrl
        }
    }

    // Explicit selection from the picker: pull the full metadata, including the
    // title (overwriting/completing whatever partial text was typed).
    private func apply(_ result: APIClient.BookSearchResult) {
        if title != result.title {
            suppressSearch = true
            title = result.title
        }
        author = result.author
        coverUrl = result.coverUrl
    }

    private func add() async {
        isLoading = true
        errorMessage = nil
        do {
            let book = try await APIClient.shared.createBook(
                clubId: clubId,
                title: title.trimmingCharacters(in: .whitespaces),
                author: author.trimmingCharacters(in: .whitespaces),
                coverUrl: coverUrl
            )
            onAdded(book)
            dismiss()
        } catch {
            errorMessage = "Failed to add book. Please try again."
        }
        isLoading = false
    }
}

struct BookPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let results: [APIClient.BookSearchResult]
    let onSelect: (APIClient.BookSearchResult) -> Void

    var body: some View {
        NavigationStack {
            List(results) { result in
                Button {
                    onSelect(result)
                } label: {
                    HStack(spacing: 12) {
                        if let urlStr = result.coverUrl, let url = URL(string: urlStr) {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.2))
                            }
                            .frame(width: 40, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 40, height: 58)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title)
                                .font(.headline)
                                .foregroundColor(.primary)
                            if !result.author.isEmpty {
                                Text(result.author)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Choose Edition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
