import SwiftUI
import AVFoundation
import AVKit
import Speech

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
                isOffline: viewModel.isOffline,
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
                        Button("Move to Future Reads") {
                            Task {
                                await viewModel.setStatus(.future)
                                onStatusChanged?(.future)
                            }
                        }
                    case .past:
                        Button("Move to Future Reads") {
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
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .task { await viewModel.load() }
        .onDisappear { Task { await viewModel.disconnect() } }
    }
}

struct MessageRow: View {
    let message: Message
    private var isMe: Bool { message.senderId == TokenStore.shared.userId }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMe {
                Spacer()
            } else {
                avatarView
                    .frame(width: 32, height: 32)
            }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 2) {
                Text(message.senderName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                messageBubble
                Text(message.sentAt, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if !isMe { Spacer() }
        }
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
    @State private var isPlaying = false
    @State private var speakerEnabled = false
    @State private var isExternalRouteActive = false
    @State private var player: AVPlayer?
    @State private var progress: Double = 0
    @State private var currentSeconds: Int = 0
    @State private var showTranscription = false
    @State private var transcription: String?
    @State private var isTranscribing = false

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
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            tickProgress()
        }
        .onAppear { updateRouteState() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            updateRouteState()
        }
        .onDisappear {
            player?.pause()
            isPlaying = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private var audioView: some View {
        HStack(spacing: 10) {
            Button { togglePlayback() } label: {
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
                            .frame(width: geo.size.width * progress, height: 3)
                    }
                }
                .frame(height: 3)

                Text(formatDuration(isPlaying ? currentSeconds : totalSeconds))
                    .font(.caption2)
                    .monospacedDigit()
            }

            if !isExternalRouteActive {
                Button { toggleSpeaker() } label: {
                    Image(systemName: speakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 14))
                        .opacity(0.8)
                        .frame(width: 24, height: 24)
                }
            }

            RoutePickerView(tintColor: isMe ? .white : .label)
                .frame(width: 24, height: 24)

            Button {
                player?.pause()
                isPlaying = false
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

    private func togglePlayback() {
        if isPlaying {
            player?.pause()
            isPlaying = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } else {
            if player == nil {
                guard let urlStr = message.mediaUrl, let url = URL(string: urlStr) else { return }
                player = AVPlayer(url: url)
            }
            activateAudioSession()
            player?.play()
            isPlaying = true
        }
    }

    private func toggleSpeaker() {
        speakerEnabled.toggle()
        if isPlaying { activateAudioSession() }
    }

    private func updateRouteState() {
        let externalPorts: Set<AVAudioSession.Port> = [
            .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .headphones
        ]
        let hasExternal = AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { externalPorts.contains($0.portType) }
        if hasExternal && speakerEnabled {
            speakerEnabled = false
            if isPlaying { activateAudioSession() }
        }
        isExternalRouteActive = hasExternal
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
        if speakerEnabled { options.insert(.defaultToSpeaker) }
        try? session.setCategory(.playAndRecord, mode: .spokenAudio, options: options)
        try? session.setActive(true)
    }

    private func tickProgress() {
        guard let player, let item = player.currentItem else { return }
        let duration = item.duration.seconds
        let current = player.currentTime().seconds
        guard duration.isFinite, duration > 0 else { return }
        progress = min(current / duration, 1.0)
        currentSeconds = Int(current)
        if current >= duration - 0.05 {
            isPlaying = false
            progress = 0
            currentSeconds = 0
            player.seek(to: .zero)
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
