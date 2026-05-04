import SwiftUI

struct BookDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: BookViewModel
    @State private var showingDeleteConfirm = false
    var onDeleted: (() -> Void)?
    var onStatusChanged: ((BookStatus) -> Void)?

    init(book: Book, onDeleted: (() -> Void)? = nil, onStatusChanged: ((BookStatus) -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: BookViewModel(book: book))
        self.onDeleted = onDeleted
        self.onStatusChanged = onStatusChanged
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoadingMessages {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.messages.isEmpty {
                Text("No discussion yet. Start the conversation!")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(viewModel.messages.reversed()) { message in
                                MessageRow(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    .onAppear {
                        if let last = viewModel.messages.first {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                TextField("Message…", text: $viewModel.messageText)
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await viewModel.sendMessage() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(viewModel.messageText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .navigationTitle(viewModel.book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    switch viewModel.book.status {
                    case .future:
                        Button("Start Reading") {
                            Task {
                                await viewModel.setStatus(.current)
                                onStatusChanged?(.current)
                            }
                        }
                    case .current:
                        Button("Mark as Finished") {
                            Task {
                                await viewModel.setStatus(.past)
                                onStatusChanged?(.past)
                            }
                        }
                        Button("Move to Book List") {
                            Task {
                                await viewModel.setStatus(.future)
                                onStatusChanged?(.future)
                            }
                        }
                    case .past:
                        Button("Move to Book List") {
                            Task {
                                await viewModel.setStatus(.future)
                                onStatusChanged?(.future)
                            }
                        }
                        Button("Mark as Currently Reading") {
                            Task {
                                await viewModel.setStatus(.current)
                                onStatusChanged?(.current)
                            }
                        }
                    }
                    Divider()
                    Button("Delete Book", role: .destructive) { showingDeleteConfirm = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Delete \"\(viewModel.book.title)\"?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await viewModel.deleteBook()
                    onDeleted?()
                    dismiss()
                }
            }
        }
        .task { await viewModel.load() }
        .onDisappear { Task { await viewModel.disconnect() } }
    }
}

struct MessageRow: View {
    let message: Message
    private var isMe: Bool { message.senderId == TokenStore.shared.userId }

    var body: some View {
        HStack {
            if isMe { Spacer() }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 2) {
                if !isMe {
                    Text(message.senderName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(message.body ?? "")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isMe ? Color.blue : Color(.systemGray5))
                    .foregroundColor(isMe ? .white : .primary)
                    .cornerRadius(16)
                Text(message.sentAt, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if !isMe { Spacer() }
        }
    }
}

struct BookDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            BookDetailView(book: Book(
                id: UUID(), clubId: UUID(),
                title: "Dune", author: "Frank Herbert",
                addedAt: Date(), finishedAt: nil, status: .future
            ))
        }
    }
}
