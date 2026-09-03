import SwiftUI

// #137 — club-admin drag-and-drop reorder of the club's book lists (originally Future Reads
// only; #144 generalized it to Currently Reading and Past Reads too — status boundaries don't
// change here, only order within each group). The order is a club-level property (one shared
// order every member sees the same way), not per-user; any club admin can change it. Presented
// from LibraryView's toolbar menu, admin-only.
//
// One screen with up to three sections (Mark's feedback after reviewing #144: three separate
// "Manage X Order" menu entries was one control too many for what's really one job — managing
// reading order). Each section reorders independently: SwiftUI's per-Section .onMove already
// confines a drag to its own section, so this doesn't risk a book crossing from one status into
// another by accident.
//
// #138 — a series drags as one unit (ReadItem) within its section, not individual books within
// it; a series' internal order (SeriesOrder) is reordered by tapping into it (SeriesOrderView)
// rather than here. On save, items are flattened back to a flat book-id list per status —
// SetReadOrder's contract didn't change; a series just always submits its members contiguously
// and in SeriesOrder, which is what keeps it displaying as one block afterward.
struct ReadOrderView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: LibraryViewModel

    @State private var currentItems: [ReadItem] = []
    @State private var futureItems: [ReadItem] = []
    @State private var pastItems: [ReadItem] = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    // #144 — a List forced into edit mode (below, for drag-to-reorder) swallows NavigationLink
    // row taps in favor of its own reorder/delete gesture, so a series row can't use
    // NavigationLink directly. Driving navigation from this instead (a plain Button still
    // works in edit mode) is the fix. Tracks which section the series belongs to, so the
    // reordered result is written back into the right array.
    @State private var seriesBeingReordered: (status: BookStatus, item: ReadItem)?

    var body: some View {
        NavigationStack {
            List {
                section(for: .current, title: "CURRENTLY READING", items: $currentItems)
                section(for: .future, title: "FUTURE READS", items: $futureItems)
                section(for: .past, title: "PAST READS", items: $pastItems)
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundColor(.red)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))   // always in reorder mode — nothing else to edit here
            .navigationTitle("Reading Order")
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
            .onAppear {
                currentItems = viewModel.currentReadGroups
                futureItems = viewModel.futureReadGroups
                pastItems = viewModel.pastReadGroups
            }
            // #144 — deployment target is iOS 16, so navigationDestination(item:) (iOS 17+)
            // isn't available; drive the same push off a Bool + separately-held item instead.
            .navigationDestination(isPresented: isSeriesBeingReorderedPresented) {
                if let entry = seriesBeingReordered, case .series(let name, let books) = entry.item {
                    SeriesOrderView(clubId: viewModel.clubId, seriesName: name, books: books) { reordered in
                        patchSeries(status: entry.status, itemId: entry.item.id, name: name, books: reordered)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section(for status: BookStatus, title: String, items: Binding<[ReadItem]>) -> some View {
        if !items.wrappedValue.isEmpty {
            Section {
                ForEach(items.wrappedValue) { item in
                    switch item {
                    case .single:
                        ReadOrderItemRow(item: item)
                    case .series:
                        Button { seriesBeingReordered = (status, item) } label: {
                            ReadOrderItemRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onMove { items.wrappedValue.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text(title)
            } footer: {
                if status == .past {
                    Text("Drag to set the order everyone in the club sees. A series moves as one block — tap a series to reorder the books within it. Any club admin can change it.")
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

    private func patchSeries(status: BookStatus, itemId: String, name: String, books: [Book]) {
        func patch(_ items: inout [ReadItem]) {
            guard let idx = items.firstIndex(where: { $0.id == itemId }) else { return }
            items[idx] = .series(name: name, books: books)
        }
        switch status {
        case .current: patch(&currentItems)
        case .future: patch(&futureItems)
        case .past: patch(&pastItems)
        }
    }

    private func save() async {
        guard let clubId = viewModel.clubId else { return }
        isSaving = true
        errorMessage = nil
        let toSave: [(BookStatus, [ReadItem])] = [(.current, currentItems), (.future, futureItems), (.past, pastItems)]
        for (status, items) in toSave where !items.isEmpty {
            do {
                try await APIClient.shared.setReadOrder(clubId: clubId, status: status, orderedBookIds: items.flatMap(\.bookIds))
            } catch APIError.serverError(409) {
                // Someone else changed this list while this admin was reordering — refetch
                // everything and let them see the current state instead of silently overwriting.
                await viewModel.load(force: true)
                currentItems = viewModel.currentReadGroups
                futureItems = viewModel.futureReadGroups
                pastItems = viewModel.pastReadGroups
                errorMessage = "The list changed elsewhere — showing the latest. Reorder and save again."
                isSaving = false
                return
            } catch {
                errorMessage = "Couldn't save the new order. Try again."
                isSaving = false
                return
            }
        }
        await viewModel.load(force: true)
        isSaving = false
        dismiss()
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
                Spacer()
                // #144 fix — a plain Button (needed so the tap survives the List's forced edit
                // mode) draws no disclosure indicator on its own, unlike the NavigationLink this
                // replaced; without this a series row gave no visual hint it was tappable at all.
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
