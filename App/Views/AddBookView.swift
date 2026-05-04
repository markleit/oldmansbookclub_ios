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

                Section("Author") {
                    TextField("e.g. Frank Herbert", text: $author)
                        .onChange(of: author) { _ in scheduleSearch() }
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
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty ||
                                      author.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let t = title.trimmingCharacters(in: .whitespaces)
        let a = author.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { coverUrl = nil; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await searchCover(title: t, author: a)
        }
    }

    private func searchCover(title: String, author: String) async {
        isSearching = true
        defer { isSearching = false }
        coverUrl = await APIClient.shared.searchBookCover(title: title, author: author)
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
