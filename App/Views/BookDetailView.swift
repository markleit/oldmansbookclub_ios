import SwiftUI
import UIKit
import AVKit
import AVFoundation
import Speech
import UserNotifications

struct BookDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: BookViewModel
    @State private var showingDeleteConfirm = false
    @AppStorage("tapToTalkEnabled") private var tapToTalk = false
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
                        LazyVStack(alignment: .leading, spacing: 8) {
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
                    .onChange(of: viewModel.visibleMessages.first?.id) { _ in
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
                pendingVideo: $viewModel.pendingVideo,
                isRecording: viewModel.isRecording,
                isUploading: viewModel.isUploading,
                isOffline: viewModel.isOffline,
                tapToTalk: tapToTalk,
                onSend: { Task { await viewModel.sendMessage() } },
                onSendPhoto: { Task { await viewModel.sendPhoto() } },
                onSendVideo: { Task { await viewModel.sendVideo() } },
                onToggleRecording: { Task { await viewModel.toggleRecording() } },
                onStartRecording: { Task { await viewModel.startRecording() } },
                onStopRecording: { Task { await viewModel.stopRecording() } },
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
            AudioPlayerService.shared.onPlaybackCompleted = { [weak viewModel] completedId in
                guard let vm = viewModel else { return }
                let voices = vm.visibleMessages.filter { $0.type == .voice && !$0.isDeleted }
                guard let idx = voices.firstIndex(where: { $0.id == completedId }),
                      idx > 0 else { return }
                AudioPlayerService.shared.toggle(message: voices[idx - 1])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task {
                // Mark stale immediately so any in-flight send waits for a rebuild,
                // even if it races ahead of the disconnect/reload below.
                await ChatService.shared.markStaleAfterBackground()
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
    @State private var showFullScreen = false
    @State private var showSenderProfile = false
    private var isMe: Bool { message.senderId == TokenStore.shared.userId }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMe {
                Spacer()
            } else if !message.isDeleted {
                Button { showSenderProfile = true } label: {
                    avatarView
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showSenderProfile) {
                    SenderProfileView(
                        senderId: message.senderId,
                        senderName: message.senderName,
                        avatarUrl: message.senderAvatarUrl
                    )
                }
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 2) {
                if message.isDeleted {
                    deletedBubble
                } else {
                    nameLabel
                    messageBubble
                    Text(formatMessageDate(message.sentAt))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if isMe {
                        readReceiptRow
                    }
                }
            }
            .fullScreenCover(isPresented: $showFullScreen) {
                if let urlStr = message.mediaUrl, let url = URL(string: urlStr) {
                    FullScreenImageView(url: url)
                }
            }
            if !isMe { Spacer() }
        }
        .contextMenu {
            if message.sendState == .failed {
                Button {
                    Task { await viewModel.retryMediaMessage(id: message.id) }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    viewModel.cancelMediaMessage(id: message.id)
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
            } else if !message.isDeleted && message.sendState == nil {
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
            CachedRemoteImage(url: url) { phase in
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

    private func avatarInitial(_ name: String) -> some View {
        Circle()
            .fill(Color(.systemGray4))
            .overlay(
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
            )
    }

    @ViewBuilder
    private var readReceiptRow: some View {
        let readers = viewModel.reads.filter { $0.lastSeenMessageId == message.id }
        return Group {
            if !readers.isEmpty {
                HStack(spacing: 4) {
                    Spacer()
                    Text("Read by")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    ForEach(readers, id: \.userId) { reader in
                        Group {
                            if let urlStr = reader.avatarUrl, let url = URL(string: urlStr) {
                                CachedRemoteImage(url: url) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFill()
                                    } else {
                                        avatarInitial(reader.displayName)
                                    }
                                }
                            } else {
                                avatarInitial(reader.displayName)
                            }
                        }
                        .frame(width: 22, height: 22)
                        .clipShape(Circle())
                    }
                }
            }
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
                PhotoMessageBubble(
                    url: url,
                    sendState: message.sendState,
                    onTap: { showFullScreen = true },
                    onRetry: { Task { await viewModel.retryMediaMessage(id: message.id) } },
                    onCancel: { viewModel.cancelMediaMessage(id: message.id) }
                )
            }

        case .voice:
            VoiceMessageBubble(
                message: message,
                isMe: isMe,
                onRetry: { Task { await viewModel.retryMediaMessage(id: message.id) } },
                onCancel: { viewModel.cancelMediaMessage(id: message.id) }
            )

        case .video:
            if let urlStr = message.mediaUrl, let url = URL(string: urlStr) {
                VideoMessageBubble(
                    url: url,
                    sendState: message.sendState,
                    onRetry: { Task { await viewModel.retryMediaMessage(id: message.id) } },
                    onCancel: { viewModel.cancelMediaMessage(id: message.id) }
                )
            }
        case .unknown:
            EmptyView()
        }
    }
}

struct VoiceMessageBubble: View {
    let message: Message
    let isMe: Bool
    var onRetry: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    @ObservedObject private var audio = AudioPlayerService.shared
    @State private var showTranscription = false
    @State private var transcription: String?
    @State private var isTranscribing = false

    private var isPlaying: Bool { audio.playingMessageId == message.id }
    private var isSending: Bool { message.sendState == .sending }
    private var isFailed: Bool { message.sendState == .failed }
    private var totalSeconds: Int { message.durationSeconds ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controlsRow
            if isFailed {
                HStack(spacing: 12) {
                    Button { onRetry?() } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.medium))
                    }
                    Button { onCancel?() } label: {
                        Text("Cancel")
                            .font(.caption)
                            .foregroundColor(isMe ? .white.opacity(0.7) : .secondary)
                    }
                }
            }
            if showTranscription {
                Divider()
                    .overlay(isPlaying || isMe ? Color.white.opacity(0.3) : Color(.systemGray3))
                transcriptionContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isPlaying ? Color(red: 0.0, green: 0.35, blue: 0.95) : (isMe ? Color.blue : Color(.systemGray5)))
        .foregroundColor(isPlaying || isMe ? .white : .primary)
        .cornerRadius(16)
        .frame(maxWidth: isPlaying || showTranscription ? .infinity : 180)
        .animation(.easeInOut(duration: 0.25), value: isPlaying)
        .animation(.easeInOut(duration: 0.2), value: showTranscription)
        .onDisappear {
            if isPlaying { audio.pause() }
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 4) {
            if isSending {
                ProgressView()
                    .frame(width: 36, height: 36)
            } else if isFailed {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(isMe ? .white.opacity(0.85) : .orange)
                    .frame(width: 36, height: 36)
            } else {
                Button { audio.toggle(message: message) } label: {
                    if isPlaying && audio.isBuffering {
                        ProgressView()
                            .frame(width: isPlaying ? 44 : 36, height: isPlaying ? 44 : 36)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: isPlaying ? 28 : 20, weight: .semibold))
                            .frame(width: isPlaying ? 44 : 36, height: isPlaying ? 44 : 36)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(isMe ? Color.white.opacity(0.35) : Color(.systemGray3))
                            .frame(height: 6)
                        Capsule()
                            .fill(isMe ? Color.white : Color.accentColor)
                            .frame(width: geo.size.width * (isPlaying ? audio.progress : 0), height: 6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard isPlaying else { return }
                        audio.seek(to: value.location.x / geo.size.width)
                    })
                }
                .frame(height: 24)

                Text(formatDuration(isPlaying ? audio.currentSeconds : totalSeconds))
                    .font(.caption2)
                    .monospacedDigit()
            }

            if isPlaying {
                Button { audio.cycleRate() } label: {
                    BunnySpeedIcon(speed: audio.playbackRate)
                        .frame(width: 44, height: 44)
                }

                RoutePickerView(tintColor: isMe ? .white : .label)
                    .frame(width: 44, height: 44)
            }

            if !isSending && !isFailed {
                Button {
                    showTranscription.toggle()
                    if showTranscription && transcription == nil && !isTranscribing {
                        Task { await transcribe() }
                    }
                } label: {
                    if isTranscribing {
                        ProgressView().scaleEffect(0.65)
                            .frame(width: isPlaying ? 44 : 36, height: isPlaying ? 44 : 36)
                    } else {
                        Image(systemName: showTranscription ? "text.bubble.fill" : "text.bubble")
                            .font(.system(size: isPlaying ? 22 : 16))
                            .frame(width: isPlaying ? 44 : 36, height: isPlaying ? 44 : 36)
                    }
                }
            }
        }
        .frame(maxWidth: isPlaying ? .infinity : 180)
    }

    private var transcriptionContent: some View {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Transcription unavailable.")
                    .font(.caption)
                    .italic()
                    .opacity(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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

private func formatMessageDate(_ date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()
    if calendar.isDateInToday(date) {
        return date.formatted(date: .omitted, time: .shortened)
    } else if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
        return date.formatted(.dateTime.weekday(.wide))
    } else {
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

struct VideoMessageBubble: View {
    let url: URL
    var sendState: MessageSendState? = nil
    var onRetry: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    @State private var showFullScreen = false

    private var isSending: Bool { sendState == .sending }
    private var isFailed: Bool { sendState == .failed }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button {
                guard !isSending && !isFailed else { return }
                showFullScreen = true
            } label: {
                VideoThumbnailView(url: url)
                    .frame(width: 240, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        if !isSending && !isFailed {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(.white, .black.opacity(0.4))
                        }
                    }
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .disabled(isSending || isFailed)
            if isSending {
                SendStateBadge(state: .sending)
                    .padding(8)
            } else if isFailed {
                SendStateBadge(state: .failed, onRetry: onRetry, onCancel: onCancel)
                    .padding(8)
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenVideoView(url: url)
        }
    }
}

// MARK: - PhotoMessageBubble

struct PhotoMessageBubble: View {
    let url: URL
    var sendState: MessageSendState? = nil
    var onTap: () -> Void
    var onRetry: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    private var isSending: Bool { sendState == .sending }
    private var isFailed: Bool { sendState == .failed }
    private var isLocalFile: Bool { url.scheme == "file" }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button {
                guard !isSending && !isFailed else { return }
                onTap()
            } label: {
                imageContent
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .disabled(isSending || isFailed)
            if isSending {
                SendStateBadge(state: .sending).padding(8)
            } else if isFailed {
                SendStateBadge(state: .failed, onRetry: onRetry, onCancel: onCancel).padding(8)
            }
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        if isLocalFile, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            CachedRemoteImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color(.systemGray5)
                        .overlay(
                            phase.isError
                                ? AnyView(Image(systemName: "photo").foregroundColor(.secondary))
                                : AnyView(ProgressView())
                        )
                }
            }
        }
    }
}

// Shared overlay for .sending / .failed bubbles. Sending → spinner badge.
// Failed → exclamation icon; tap shows a small Retry/Cancel menu.
struct SendStateBadge: View {
    let state: MessageSendState
    var onRetry: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    var body: some View {
        switch state {
        case .sending:
            ProgressView()
                .tint(.white)
                .padding(8)
                .background(Color.black.opacity(0.55))
                .clipShape(Circle())
        case .failed:
            Menu {
                Button { onRetry?() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                Button(role: .destructive) { onCancel?() } label: { Label("Cancel", systemImage: "xmark") }
            } label: {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white, .red)
                    .padding(4)
                    .background(Color.black.opacity(0.3))
                    .clipShape(Circle())
            }
        }
    }
}

struct FullScreenVideoView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
            Button {
                player?.pause()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .padding()
            }
        }
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try? AVAudioSession.sharedInstance().setActive(true)
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

// MARK: - Bunny Speed Icon

struct BunnySpeedIcon: View {
    let speed: Float

    private var lineCount: Int {
        switch speed {
        case 1.0: return 0
        case 1.5: return 1
        case 2.0: return 2
        case 3.0: return 3
        default:  return 4
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .frame(width: CGFloat(8 - i * 1), height: 2)
                        .opacity(i < lineCount ? (1.0 - Double(i) * 0.18) : 0)
                }
            }
            .frame(width: 12)

            Image(systemName: speed <= 1.0 ? "hare" : "hare.fill")
                .font(.system(size: 14 + CGFloat(lineCount) * 2,
                              weight: speed >= 4.0 ? .bold : .regular))
        }
    }
}

struct FullScreenImageView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(dragOffset)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { scale = $0 }
                                .onEnded { _ in withAnimation { scale = max(1.0, scale) } }
                        )
                        .gesture(
                            DragGesture()
                                .onChanged { if scale <= 1.0 { dragOffset = $0.translation } }
                                .onEnded { value in
                                    if scale <= 1.0 && abs(value.translation.height) > 80 {
                                        dismiss()
                                    } else {
                                        withAnimation { dragOffset = .zero }
                                    }
                                }
                        )
                } else if phase.error != nil {
                    Image(systemName: "photo")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary)
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white, Color.black.opacity(0.5))
                    .padding()
            }
        }
    }
}

struct SenderProfileView: View {
    let senderId: UUID
    let senderName: String
    let avatarUrl: String?
    @Environment(\.dismiss) private var dismiss
    @State private var avatarImage: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Group {
                        if let image = avatarImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Circle()
                                .fill(Color(.systemGray4))
                                .overlay(
                                    Text(String(senderName.prefix(1)).uppercased())
                                        .font(.system(size: 40, weight: .semibold))
                                        .foregroundColor(.white)
                                )
                        }
                    }
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
                    .padding(.top, 32)

                    Text(senderName)
                        .font(.title2)
                        .bold()
                }
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(senderName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard let urlStr = avatarUrl, let url = URL(string: urlStr) else { return }
                if let cached = ImageCache.shared[url] { avatarImage = cached; return }
                let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
                guard let (data, _) = try? await URLSession.shared.data(for: request),
                      let img = UIImage(data: data) else { return }
                ImageCache.shared[url] = img
                avatarImage = img
            }
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
