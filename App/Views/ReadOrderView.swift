import SwiftUI

// #137 — club-admin drag-and-drop reorder of one status group (originally Future Reads only;
// #144 generalized it to Currently Reading and Past Reads too — status boundaries don't change
// here, only order within the group). The order is a club-level property (one shared order
// every member sees the same way), not per-user; any club admin can change it. Presented from
// LibraryView's toolbar menu, admin-only.
//
// #138 — drags whole series as one unit (ReadItem), not individual books within a series; a
// series' internal order (SeriesOrder) is reordered by tapping into it (#144's SeriesOrderView)
// rather than here. On save, items are flattened back to a flat book-id list — SetReadOrder's
// contract never changed; a series just always submits its members contiguously and in
// SeriesOrder, which is what keeps it displaying as one block afterward.
struct ReadOrderView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: LibraryViewModel
    let status: BookStatus

    @State private var orderedItems: [ReadItem] = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    // #144 — a List forced into edit mode (below, for drag-to-reorder) swallows NavigationLink
    // row taps in favor of its own reorder/delete gesture, so a series row can't use
    // NavigationLink directly. Driving navigation from this instead (a plain Button still
    // works in edit mode) is the fix.
    @State private var seriesBeingReordered: ReadItem?

    private var title: String {
        switch status {
        case .current: return "Currently Reading Order"
        case .future: return "Future Read Order"
        case .past: return "Past Read Order"
        }
    }

    private var sourceItems: [ReadItem] {
        switch status {
        case .current: return viewModel.currentReadGroups
        case .future: return viewModel.futureReadGroups
        case .past: return viewModel.pastReadGroups
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(orderedItems) { item in
                        switch item {
                        case .single:
                            ReadOrderItemRow(item: item)
                        case .series:
                            Button { seriesBeingReordered = item } label: {
                                ReadOrderItemRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onMove { orderedItems.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundColor(.red)
                    } else {
                        Text("Drag to set the order everyone in the club sees. A series moves as one block — tap a series to reorder the books within it. Any club admin can change it.")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))   // always in reorder mode — nothing else to edit here
            .navigationTitle(title)
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
            .onAppear { orderedItems = sourceItems }
            // #144 — deployment target is iOS 16, so navigationDestination(item:) (iOS 17+)
            // isn't available; drive the same push off a Bool + separately-held item instead.
            .navigationDestination(isPresented: isSeriesBeingReorderedPresented) {
                if let item = seriesBeingReordered, case .series(let name, let books) = item {
                    SeriesOrderView(clubId: viewModel.clubId, seriesName: name, books: books) { reordered in
                        guard let idx = orderedItems.firstIndex(where: { $0.id == item.id }) else { return }
                        orderedItems[idx] = .series(name: name, books: reordered)
                    }
                }
            }
        }
    }

    private var isSeriesBeingReorderedPresented: Binding<Bool> {
        Binding(
            get: { seriesBeingReordered != nil },
            set: { if !$0 { seriesBeingReordered = nil } }
        )
    }

    private func save() async {
        guard let clubId = viewModel.clubId else { return }
        isSaving = true
        errorMessage = nil
        let orderedBookIds = orderedItems.flatMap(\.bookIds)
        do {
            try await APIClient.shared.setReadOrder(clubId: clubId, status: status, orderedBookIds: orderedBookIds)
            await viewModel.load(force: true)
            dismiss()
        } catch APIError.serverError(409) {
            // Someone else changed this list while this admin was reordering — refetch and let
            // them see the current state instead of silently overwriting it.
            await viewModel.load(force: true)
            orderedItems = sourceItems
            errorMessage = "This list changed elsewhere — showing the latest. Reorder and save again."
        } catch {
            errorMessage = "Couldn't save the new order. Try again."
        }
        isSaving = false
    }
}

private struct ReadOrderItemRow: View {
    let item: ReadItem

    var body: some View {
        switch item {
        case .single(let book):
            HStack(spacing: 12) {
                CachedBookCover(urlString: book.coverBlobUrl, width: 32, height: 46, cornerRadius: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).font(.subheadline).fontWeight(.medium)
                    Text(book.author).font(.caption).foregroundColor(.secondary)
                }
            }

        case .series(let name, let books):
            HStack(spacing: 12) {
                CachedBookCover(urlString: books.first?.coverBlobUrl, width: 32, height: 46, cornerRadius: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.subheadline).fontWeight(.medium)
                    Text("Series · \(books.count) book\(books.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// #144 — reorder the books within one series (SeriesOrder). Reached by tapping a series row
// inside ReadOrderView; saves immediately on move-confirm rather than needing its own explicit
// Save, matching how a NavigationLink push (not a modal) is expected to behave — Back just goes
// back once the save completes.
private struct SeriesOrderView: View {
    @Environment(\.dismiss) private var dismiss
    let clubId: UUID?
    let seriesName: String
    let books: [Book]
    let onSaved: ([Book]) -> Void

    @State private var orderedBooks: [Book]
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(clubId: UUID?, seriesName: String, books: [Book], onSaved: @escaping ([Book]) -> Void) {
        self.clubId = clubId
        self.seriesName = seriesName
        self.books = books
        self.onSaved = onSaved
        _orderedBooks = State(initialValue: books)
    }

    var body: some View {
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
                    Text("Drag to set the order within \(seriesName).")
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(seriesName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save() } }
                }
            }
        }
    }

    private func save() async {
        guard let clubId else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await APIClient.shared.setSeriesOrder(clubId: clubId, seriesName: seriesName, orderedBookIds: orderedBooks.map(\.id))
            onSaved(orderedBooks)
            dismiss()
        } catch APIError.serverError(409) {
            errorMessage = "This series changed elsewhere. Go back, reopen it, and try again."
        } catch {
            errorMessage = "Couldn't save the new order. Try again."
        }
        isSaving = false
    }
}
