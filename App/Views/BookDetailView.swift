import SwiftUI

struct BookDetailView: View {
    @StateObject private var viewModel: BookViewModel
    @State private var showingFinishConfirm = false

    init(book: Book) {
        _viewModel = StateObject(wrappedValue: BookViewModel(book: book))
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
            if viewModel.book.isCurrentRead {
                ToolbarItem(placement: .primaryAction) {
                    Button("Finish") { showingFinishConfirm = true }
                        .foregroundColor(.green)
                }
            }
        }
        .confirmationDialog(
            "Mark \"\(viewModel.book.title)\" as finished?",
            isPresented: $showingFinishConfirm,
            titleVisibility: .visible
        ) {
            Button("Mark as Finished", role: .none) {
                Task { await viewModel.finishBook() }
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
                addedAt: Date(), finishedAt: nil
            ))
        }
    }
}
