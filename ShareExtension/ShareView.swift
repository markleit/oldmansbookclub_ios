import SwiftUI

// #178 — "Send to…" picker → compose (preview + optional caption) → Send with progress.
struct ShareView: View {
    @ObservedObject var model: ShareModel
    let onCancel: () -> Void

    @State private var chosen: ShareBook?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(chosen == nil ? "Send to…" : chosen!.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if chosen != nil, !isSending, model.remaining == nil {
                            Button("Back") { chosen = nil }
                        } else {
                            Button("Cancel", action: onCancel).disabled(isSending)
                        }
                    }
                    if chosen != nil {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Send") { send() }
                                .bold()
                                .disabled(isSending)
                                .accessibilityIdentifier("shareSendButton")
                        }
                    }
                }
        }
    }

    private var isSending: Bool {
        if case .sending = model.phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            message("person.crop.circle.badge.exclamationmark", ShareError.signedOut.localizedDescription)
        case .failedToLoad(let text):
            message("exclamationmark.triangle", text)
        case .ready, .sending, .failedToSend:
            if let book = chosen { compose(book) } else { picker }
        }
    }

    private var picker: some View {
        List {
            ForEach(model.sections) { section in
                Section(section.name) {
                    ForEach(section.books) { book in
                        Button { chosen = book } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(book.title).foregroundStyle(.primary)
                                    Text(book.author).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if book.status == "current" {
                                    Text("Reading").font(.caption2.bold())
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        // Rows read as a list of chats, not as blue link-styled buttons.
                        .tint(.primary)
                    }
                }
            }
        }
    }

    private func compose(_ book: ShareBook) -> some View {
        Form {
            Section {
                preview
            }
            Section {
                TextField(model.photoCount > 0 ? "Add a message (optional)" : "Add a note (optional)",
                          text: $model.caption, axis: .vertical)
                    .lineLimit(1...5)
                    .disabled(isSending || model.remaining != nil)
            }
            switch model.phase {
            case .sending(let done, let total, let label):
                Section {
                    ProgressView(value: Double(done), total: Double(max(total, 1))) {
                        Text(label)
                    }
                }
            case .failedToSend(let text):
                Section {
                    Label(text, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    Button("Try Again") { send() }
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        let photos: [(UUID, UIImage)] = model.items.compactMap {
            if case .photo(let id, _, let thumb) = $0 { return (id, thumb) } else { return nil }
        }
        if !photos.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(photos, id: \.0) { _, thumb in
                        Image(uiImage: thumb).resizable().scaledToFill()
                            .frame(width: 88, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        ForEach(model.items) { item in
            switch item {
            case .link(_, let url):
                Label(url.absoluteString, systemImage: "link").lineLimit(2)
            case .text(_, let text):
                Text(text).lineLimit(6)
            case .photo:
                EmptyView()
            }
        }
    }

    private func message(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func send() {
        guard let book = chosen else { return }
        Task { await model.send(to: book) }
    }
}
