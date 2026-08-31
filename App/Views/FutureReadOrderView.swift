import SwiftUI

// #137 — club-admin drag-and-drop reorder of the Future Reads queue. The order is a club-level
// property (one shared queue every member sees the same way), not per-user; any club admin can
// change it. Presented from LibraryView's toolbar menu, admin-only.
struct FutureReadOrderView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: LibraryViewModel

    @State private var orderedBooks: [Book] = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(orderedBooks) { book in
                        HStack(spacing: 12) {
                            CachedBookCover(urlString: book.coverBlobUrl, width: 32, height: 46, cornerRadius: 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(book.title).font(.subheadline).fontWeight(.medium)
                                Text(book.author).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .onMove { orderedBooks.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundColor(.red)
                    } else {
                        Text("Drag to set the order everyone in the club sees. Any club admin can change it.")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))   // always in reorder mode — nothing else to edit here
            .navigationTitle("Future Read Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                    }
                }
            }
            .onAppear { orderedBooks = viewModel.bookList }
        }
    }

    private func save() async {
        guard let clubId = viewModel.clubId else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await APIClient.shared.setFutureReadOrder(clubId: clubId, orderedBookIds: orderedBooks.map(\.id))
            await viewModel.load(force: true)
            dismiss()
        } catch APIError.serverError(409) {
            // Someone else changed the future-read list while this admin was reordering —
            // refetch and let them see the current state instead of silently overwriting it.
            await viewModel.load(force: true)
            orderedBooks = viewModel.bookList
            errorMessage = "Future reads changed elsewhere — showing the latest list. Reorder and save again."
        } catch {
            errorMessage = "Couldn't save the new order. Try again."
        }
        isSaving = false
    }
}
