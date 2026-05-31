import SwiftUI
import UIKit
import AVFoundation
import AVKit
import Speech
import UserNotifications

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
            if viewModel.isOffline {
                Label("Offline — showing cached messages", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray6))
            }

            if viewModel.isLoadingMessages {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.messages.isEmpty {
                Text("No discussion yet. Start the conversation!")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(viewModel.visibleMessages.reversed()) { message in
                                MessageRow(message: message, viewModel: viewModel)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    .onAppear {
                        if let newest = viewModel.visibleMessages.first {
                            proxy.scrollTo(newest.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: viewModel.visibleMessages.count) { _ in
                        if let newest = viewModel.visibleMessages.first {
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
                isOffline: viewModel.isOffline,
                onSend: { Task { await viewModel.sendMessage() } },
                onSendPhoto: { Task { await viewModel.sendPhoto() } },
                onToggleRecording: { Task { await viewModel.toggleRecording() } },
                onShowSaved: { viewModel.showSavedMessages = true }
            )
        }
        .navigationTitle(viewModel.book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu { bookMenuItems } label: {
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
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("Microphone Access Required", isPresented: $viewModel.showMicDeniedAlert) {
            Button("Not Now", role: .cancel) {}
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text("Voice messages require microphone access. You can enable it in Settings.")
        }
        .sheet(isPresented: $viewModel.showSavedMessages) {
            SavedMessagesSheet(viewModel: viewModel)
        }
        .overlay(alignment: .top) {
            if viewModel.messageSaved {
                Label("Message saved", systemImage: "bookmark.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(duration: 0.3), value: viewModel.messageSaved)
            }
        }
        .task {
            await viewModel.load()
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task {
                // Force-clear any stale connection from OS background suspension
                await ChatService.shared.disconnect()
                await viewModel.load()
            }
        }
        .onDisappear { viewModel.disconnect() }
    }

    @ViewBuilder
    private var bookMenuItems: some View {
        switch viewModel.book.status {
        case .future:
            Button("Start Reading") {
                Task { await viewModel.setStatus(.current); onStatusChanged?(.current) }
            }
        case .current:
            Button("Mark as Finished") {
                Task { await viewModel.setStatus(.past); onStatusChanged?(.past) }
            }
            Button("Move to Future Reads") {
                Task { await viewModel.setStatus(.future); onStatusChanged?(.future) }
            }
        case .past:
            Button("Move to Future Reads") {
                Task { await viewModel.setStatus(.future); onStatusChanged?(.future) }
            }
            Button("Mark as Currently Reading") {
                Task { await viewModel.setStatus(.current); onStatusChanged?(.current) }
            }
        }
        Divider()
        Button("Delete Book", role: .destructive) { showingDeleteConfirm = true }
    }
}

struct MessageRow: View {
    let message: Message
    @ObservedObject var viewModel: BookViewModel
    private var isMe: Bool { message.senderId == TokenStore.shared.userId }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMe {
                Spacer()
            } else if !message.isDeleted {
                avatarView
                    .frame(width: 32, height: 32)
            } else {
                Color.clear.frame(width: 32, height: 32)
            }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 2) {
                if message.isDeleted {
                    deletedBubble
                } else {
                    nameLabel
                    messageBubble
                    Text(message.sentAt, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            if !isMe { Spacer() }
        }
        .contextMenu {
            if !message.isDeleted {
                Button {
                    Task { await viewModel.saveMessage(id: message.id) }
                } label: {
                    Label("Save", systemImage: "bookmark")
                }
                if isMe {
                    Button(role: .destructive) {
                        Task { await viewModel.deleteMessage(id: message.id) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } else {
                    Button {
                        Task { await viewModel.reportMessage(id: message.id) }
                    } label: {
                        Label("Report", systemImage: "flag")
                    }
                    Button(role: .destructive) {
                        Task { await viewModel.blockUser(senderId: message.senderId) }
                    } label: {
                        Label("Block User", systemImage: "hand.raised")
                    }
                }
            }
        }
    }

    private var nameLabel: some View {
        Group {
            if message.isForwarded {
                Text("Forwarded by \(message.senderName)")
                    .italic()
            } else {
                Text(message.senderName)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    private var deletedBubble: some View {
        Text("This message was deleted")
            .font(.subheadline)
            .italic()
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .cornerRadius(16)
    }

    @ViewBuilder
    private var avatarView: some View {
        if let urlStr = message.senderAvatarUrl, let url = URL(string: urlStr) {
            AsyncImage(url: url) { phase in
                if let img = phase.image {
                    img.resizable().scaledToFill()
                } else {
                    avatarPlaceholder
                }
            }
            .clipShape(Circle())
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(Color(.systemGray4))
            .overlay(
                Text(String(message.senderName.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            )
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
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 200, height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        Color(.systemGray5)
                            .frame(width: 200, height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(
                                phase.error != nil
                                    ? AnyView(Image(systemName: "photo").foregroundColor(.secondary))
                                    : AnyView(ProgressView())
                            )
                    }
                }
            }

        case .voice:
            VoiceMessageBubble(message: message, isMe: isMe)
        }
    }
}

struct VoiceMessageBubble: View {
    let message: Message
    let isMe: Bool
    @ObservedObject private var audio = AudioPlayerService.shared
    @State private var showTranscription = false
    @State private var transcription: String?
    @State private var isTranscribing = false

    private var isPlaying: Bool { audio.playingMessageId == message.id }
    private var totalSeconds: Int { message.durationSeconds ?? 0 }

    var body: some View {
        Group {
            if showTranscription {
                transcriptionView
            } else {
                audioView
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isMe ? Color.blue : Color(.systemGray5))
        .foregroundColor(isMe ? .white : .primary)
        .cornerRadius(16)
        .animation(.easeInOut(duration: 0.2), value: showTranscription)
        .onDisappear {
            if isPlaying { audio.pause() }
        }
    }

    private var audioView: some View {
        HStack(spacing: 10) {
            Button { audio.toggle(message: message) } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(isMe ? Color.white.opacity(0.35) : Color(.systemGray3))
                            .frame(height: 3)
                        Capsule()
                            .fill(isMe ? Color.white : Color.accentColor)
                            .frame(width: geo.size.width * (isPlaying ? audio.progress : 0), height: 3)
                    }
                }
                .frame(height: 3)

                Text(formatDuration(isPlaying ? audio.currentSeconds : totalSeconds))
                    .font(.caption2)
                    .monospacedDigit()
            }

            if !audio.isExternalRouteActive {
                Button { audio.setSpeaker(!audio.speakerEnabled) } label: {
                    Image(systemName: audio.speakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 14))
                        .opacity(0.8)
                        .frame(width: 24, height: 24)
                }
            }

            RoutePickerView(tintColor: isMe ? .white : .label)
                .frame(width: 24, height: 24)

            Button {
                if isPlaying { audio.pause() }
                showTranscription = true
                if transcription == nil && !isTranscribing {
                    Task { await transcribe() }
                }
            } label: {
                if isTranscribing {
                    ProgressView().scaleEffect(0.65).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 14))
                        .opacity(0.7)
                }
            }
        }
        .frame(width: 275)
    }

    private var transcriptionView: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if isTranscribing {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Transcribing…")
                            .font(.caption)
                            .italic()
                    }
                } else if let text = transcription {
                    Text(text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Transcription unavailable.")
                        .font(.caption)
                        .italic()
                        .opacity(0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                showTranscription = false
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 16))
            }
        }
        .frame(minWidth: 220, maxWidth: 300)
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func transcribe() async {
        isTranscribing = true
        defer { isTranscribing = false }

        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else { return }

        guard let urlStr = message.mediaUrl, let remoteURL = URL(string: urlStr) else { return }

        guard let (tmpURL, _) = try? await URLSession.shared.download(from: remoteURL) else { return }
        let m4aURL = tmpURL.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.moveItem(at: tmpURL, to: m4aURL)
        defer { try? FileManager.default.removeItem(at: m4aURL) }

        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return }

        let request = SFSpeechURLRecognitionRequest(url: m4aURL)
        request.shouldReportPartialResults = false

        let result = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<SFSpeechRecognitionResult, Error>) in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error { finished = true; cont.resume(throwing: error) }
                else if let result, result.isFinal { finished = true; cont.resume(returning: result) }
            }
        }

        transcription = result?.bestTranscription.formattedString
    }
}

struct RoutePickerView: UIViewRepresentable {
    var tintColor: UIColor = .label

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tintColor
        view.activeTintColor = .systemBlue
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
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
