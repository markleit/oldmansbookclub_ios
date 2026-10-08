import SwiftUI
import PhotosUI

struct AddBookView: View {
    @Environment(\.dismiss) private var dismiss
    let clubId: UUID
    // Non-nil = edit an existing book (title/author/series/cover); nil = add a new book.
    private let editingBook: Book?
    var onSaved: (Book) -> Void

    init(clubId: UUID, editingBook: Book? = nil, onSaved: @escaping (Book) -> Void) {
        self.clubId = clubId
        self.editingBook = editingBook
        self.onSaved = onSaved
        _title = State(initialValue: editingBook?.title ?? "")
        _author = State(initialValue: editingBook?.author ?? "")
        _coverUrl = State(initialValue: editingBook?.coverBlobUrl)
        _seriesName = State(initialValue: editingBook?.seriesName ?? "")
    }

    private var isEditing: Bool { editingBook != nil }

    @State private var title = ""
    @State private var author = ""
    @State private var coverUrl: String?
    @State private var seriesName = ""
    @State private var isSearching = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchResults: [APIClient.BookSearchResult] = []
    @State private var showingPicker = false
    @State private var searchTask: Task<Void, Never>?
    // Set true right before we fill the title from a picked result, so its
    // .onChange doesn't kick off another search and clobber the selection.
    @State private var suppressSearch = false
    // Edit Book → Change Cover (2.1): a photo from the library (uploaded on Save), or another
    // Google Books edition's cover. `coverChanged` decides whether Save sends a cover at all —
    // untouched, the server leaves the existing one alone.
    @State private var newCoverImage: UIImage?
    @State private var coverChanged = false
    @State private var showingCoverPhotoPicker = false
    @State private var coverPickerItem: PhotosPickerItem?
    @State private var isFindingCovers = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Dune", text: $title)
                        .accessibilityIdentifier("bookTitleField")
                        .onChange(of: title) { _ in
                            // Editing an existing book is manual only — no live search
                            // clobbering the title/author/cover the admin is correcting.
                            guard !isEditing else { return }
                            if suppressSearch { suppressSearch = false; return }
                            scheduleSearch()
                        }
                } header: {
                    Text("Title")
                } footer: {
                    if !isEditing {
                        Text("Start typing to search for cover art and author.")
                    }
                }

                if isEditing || isSearching || coverUrl != nil {
                    Section("Cover") {
                        HStack {
                            if let newCoverImage {
                                Image(uiImage: newCoverImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 80, height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .accessibilityIdentifier("chosenCoverImage")
                            } else if isSearching || isFindingCovers {
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
                            } else if isEditing {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 80, height: 120)
                                    .overlay(Image(systemName: "book.closed").foregroundColor(.secondary))
                            }
                            Spacer()
                            if isEditing {
                                Menu {
                                    Button {
                                        showingCoverPhotoPicker = true
                                    } label: {
                                        Label("Choose Photo", systemImage: "photo")
                                    }
                                    Button {
                                        Task { await findGoogleCovers() }
                                    } label: {
                                        Label("Search Google Books", systemImage: "magnifyingglass")
                                    }
                                } label: {
                                    Text("Change Cover")
                                }
                                .accessibilityIdentifier("changeCoverMenu")
                                .disabled(isFindingCovers || isLoading)
                            }
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
                        if !searchResults.isEmpty && !isEditing {
                            Button(searchResults.count > 1 ? "Choose edition" : "Use match") {
                                showingPicker = true
                            }
                            .font(.caption)
                        }
                    }
                }

                Section {
                    TextField("e.g. Dune", text: $seriesName)
                        .accessibilityIdentifier("bookSeriesField")
                    // A native Menu instead of a horizontal-scroll chip row (that had no visible
                    // scroll affordance past 2-3 items) — matches the Menu pattern already used
                    // elsewhere in this app (club switcher, toolbar ⋯), and scales to any number
                    // of series without extra layout code.
                    if !existingSeriesNames.isEmpty {
                        Menu {
                            ForEach(existingSeriesNames, id: \.self) { name in
                                Button(name) { seriesName = name }
                            }
                        } label: {
                            Label("Choose existing series", systemImage: "chevron.up.chevron.down")
                                .font(.subheadline)
                        }
                    }
                } header: {
                    Text("Series (optional)")
                } footer: {
                    Text("Books with the same series name group together in Future Reads and reorder as one block.")
                }

                if let error = errorMessage {
                    Section {
                        Text(error).foregroundColor(.red).font(.caption)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Book" : "Add Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Button(isEditing ? "Save" : "Add") { Task { await save() } }
                            .accessibilityIdentifier("saveBookButton")
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showingPicker) {
                BookPickerSheet(results: isEditing ? searchResults.filter { $0.coverUrl != nil } : searchResults) { result in
                    apply(result)
                    showingPicker = false
                }
            }
            .photosPicker(isPresented: $showingCoverPhotoPicker, selection: $coverPickerItem, matching: .images)
            .onChange(of: coverPickerItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        newCoverImage = image
                        coverChanged = true
                    }
                    coverPickerItem = nil
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

    // Edit Book → Change Cover → Search Google Books: other editions of this title, to pick a
    // different cover. Only the cover changes — the title/author being edited are left alone.
    private func findGoogleCovers() async {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return }
        isFindingCovers = true
        defer { isFindingCovers = false }
        searchResults = await APIClient.shared.searchBooks(title: t)
        if searchResults.contains(where: { $0.coverUrl != nil }) {
            showingPicker = true
        } else {
            errorMessage = "No Google Books covers found for this title."
        }
    }

    // Explicit selection from the picker: pull the full metadata, including the
    // title (overwriting/completing whatever partial text was typed).
    private func apply(_ result: APIClient.BookSearchResult) {
        if isEditing {
            guard let cover = result.coverUrl else { return }
            newCoverImage = nil
            coverUrl = cover
            coverChanged = true
            return
        }
        if title != result.title {
            suppressSearch = true
            title = result.title
        }
        author = result.author
        coverUrl = result.coverUrl
    }

    // #138 — series names already used in this club, offered as one-tap suggestions so a typo
    // doesn't silently create a second, orphaned group (free-text has no FK to catch that).
    // Sourced from the local book cache rather than a new endpoint — LibraryViewModel already
    // keeps this current for every club the user is in.
    private var existingSeriesNames: [String] {
        var seen = Set<String>()
        return LibraryViewModel.cachedBooks()
            .filter { $0.clubId == clubId }
            .compactMap { $0.seriesName }
            .filter { seen.insert($0).inserted }
    }

    private func save() async {
        isLoading = true
        errorMessage = nil
        let t = title.trimmingCharacters(in: .whitespaces)
        let a = author.trimmingCharacters(in: .whitespaces)
        let s = seriesName.trimmingCharacters(in: .whitespaces)
        do {
            let book: Book
            if let editing = editingBook {
                // A chosen photo goes up first, the same way chat photos do (club media); a picked
                // Google edition sends its URL as-is; an untouched cover sends nothing.
                var newCover: String?
                if let image = newCoverImage,
                   let data = image.resizedForUpload(maxDimension: 1000).jpegData(compressionQuality: 0.8) {
                    let upload = try await APIClient.shared.getUploadUrl(clubId: editing.clubId, ext: "jpg")
                    guard let uploadUrl = URL(string: upload.uploadUrl) else { throw URLError(.badURL) }
                    try await APIClient.shared.uploadMedia(data: data, to: uploadUrl, contentType: "image/jpeg")
                    newCover = upload.mediaUrl
                } else if coverChanged {
                    newCover = coverUrl
                }
                book = try await APIClient.shared.updateBook(bookId: editing.id, title: t, author: a,
                                                             seriesName: s.isEmpty ? nil : s, coverUrl: newCover)
            } else {
                book = try await APIClient.shared.createBook(clubId: clubId, title: t, author: a, coverUrl: coverUrl, seriesName: s.isEmpty ? nil : s)
            }
            onSaved(book)
            dismiss()
        } catch {
            errorMessage = isEditing ? "Failed to save changes. Please try again." : "Failed to add book. Please try again."
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
