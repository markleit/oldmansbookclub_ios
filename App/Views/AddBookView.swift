import SwiftUI

struct AddBookView: View {
    @Environment(\.dismiss) private var dismiss
    let clubId: UUID
    var onAdded: (Book) -> Void

    @State private var title = ""
    @State private var author = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section("Title") {
                    TextField("e.g. Dune", text: $title)
                }

                Section("Author") {
                    TextField("e.g. Frank Herbert", text: $author)
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

    private func add() async {
        isLoading = true
        errorMessage = nil
        do {
            let book = try await APIClient.shared.createBook(
                clubId: clubId,
                title: title.trimmingCharacters(in: .whitespaces),
                author: author.trimmingCharacters(in: .whitespaces)
            )
            onAdded(book)
            dismiss()
        } catch {
            errorMessage = "Failed to add book. Please try again."
        }
        isLoading = false
    }
}
