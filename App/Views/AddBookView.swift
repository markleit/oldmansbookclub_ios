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

    var body: some View {
        NavigationView {
            Form {
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
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 80, height: 120)
                                .overlay(
                                    Text("Cover\npreview")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                )
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                Section("Title") {
                    TextField("e.g. Dune", text: $title)
                        .onChange(of: title) { _ in scheduleSearch() }
                }

                Section {
                    TextField("Author", text: $author)
                } header: {
                    HStack {
                        Text("Author")
                        Spacer()
                        if searchResults.count > 1 {
                            Button("Choose edition") { showingPicker = true }
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
        if let first = results.first {
            apply(first)
        }
    }

    private func apply(_ result: APIClient.BookSearchResult) {
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
        NavigationView {
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
