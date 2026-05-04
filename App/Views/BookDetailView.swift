import SwiftUI
import AVFoundation

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
                        if let newest = viewModel.messages.first {
                            proxy.scrollTo(newest.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: viewModel.messages.count) { _ in
                        if let newest = viewModel.messages.first {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(newest.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            MessageInputView(
                text: $viewModel.messageText,
                pendingImage: $viewModel.pendingImage,
                isRecording: viewModel.isRecording,
                isUploading: viewModel.isUploading,
                onSend: { Task { await viewModel.sendMessage() } },
                onSendPhoto: { Task { await viewModel.sendPhoto() } },
                onToggleRecording: { Task { await viewModel.toggleRecording() } }
            )
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
                messageBubble
                Text(message.sentAt, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if !isMe { Spacer() }
        }
    }

    @ViewBuilder
    private var messageBubble: some View {
        switch message.type {
        case .text:
            Text(message.body ?? "")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isMe ? Color.blue : Color(.systemGray5))
                .foregroundColor(isMe ? .white : .primary)
                .cornerRadius(16)

        case .photo:
            if let urlStr = message.mediaUrl, let url = URL(string: urlStr) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color(.systemGray5).overlay(ProgressView())
                }
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }

        case .voice:
            VoiceMessageBubble(message: message, isMe: isMe)
        }
    }
}

struct VoiceMessageBubble: View {
    let message: Message
    let isMe: Bool
    @State private var isPlaying = false
    @State private var player: AVPlayer?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.body)
            }
            Image(systemName: "waveform")
                .font(.title3)
            if let duration = message.durationSeconds {
                Text(formatDuration(duration))
                    .font(.caption)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isMe ? Color.blue : Color(.systemGray5))
        .foregroundColor(isMe ? .white : .primary)
        .cornerRadius(16)
        .onDisappear { player?.pause() }
    }

    private func togglePlayback() {
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            guard let urlStr = message.mediaUrl, let url = URL(string: urlStr) else { return }
            player = AVPlayer(url: url)
            player?.play()
            isPlaying = true
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                object: player?.currentItem, queue: .main) { _ in isPlaying = false }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
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
