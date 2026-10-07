import SwiftUI
import AVKit

// Saved Messages (#192, #14). Tapping a saved message OPENS it — photo/video full screen, text in
// full, voice plays in the row — and never sends anything. Forwarding is its own action (the ↗
// button or a leading swipe) that asks which chat, confirms, and stays here with a toast.
struct SavedMessagesSheet: View {
    @ObservedObject var viewModel: BookViewModel
    @State private var viewing: ViewedMedia?
    @State private var forwarding: SavedMessage?
    @State private var toast: Toast?
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Group {
                if viewModel.isLoadingSaved {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.savedMessages.isEmpty {
                    Text("No saved messages yet.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(viewModel.savedMessages) { saved in
                            row(saved)
                                .swipeActions(edge: .leading) {
                                    if !saved.isDeleted {
                                        Button { forwarding = saved } label: {
                                            Label("Forward", systemImage: "arrowshape.turn.up.right")
                                        }
                                        .tint(.accentColor)
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        Task { await viewModel.unsaveSavedMessage(savedMessage: saved) }
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Saved Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { viewModel.showSavedMessages = false }
                }
            }
        }
        .toast($toast)
        .fullScreenCover(item: $viewing) { media in
            switch media.kind {
            case .photo: FullScreenImageView(url: media.url)
            case .video: FullScreenVideoView(url: media.url)
            }
        }
        .sheet(item: $forwarding) { saved in
            ForwardPickerSheet(currentBook: viewModel.book) { book in
                forwarding = nil
                Task { await forward(saved, to: book) }
            }
        }
        .alert("Couldn't Forward", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await viewModel.loadSavedMessages() }
    }

    @ViewBuilder
    private func row(_ saved: SavedMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            rowContent(saved)
            if !saved.isDeleted {
                Button { forwarding = saved } label: {
                    Image(systemName: "arrowshape.turn.up.right")
                        .font(.system(size: 17))
                        .foregroundColor(.accentColor)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Forward message")
                .accessibilityIdentifier("savedForward")
            }
        }
    }

    @ViewBuilder
    private func rowContent(_ saved: SavedMessage) -> some View {
        let url = saved.mediaUrl.flatMap(URL.init(string:))
        if saved.isDeleted || saved.type == .voice || saved.type == .unknown {
            // Voice plays from its own button in the row; deleted rows have nothing to open.
            SavedMessageRow(saved: saved)
        } else if saved.type == .text {
            NavigationLink {
                SavedTextDetail(saved: saved)
            } label: {
                SavedMessageRow(saved: saved)
            }
        } else if let url {
            Button {
                viewing = ViewedMedia(url: url, kind: saved.type == .photo ? .photo : .video)
            } label: {
                SavedMessageRow(saved: saved)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("savedOpen")
        } else {
            SavedMessageRow(saved: saved)
        }
    }

    private func forward(_ saved: SavedMessage, to book: Book) async {
        if await viewModel.forwardMessage(savedMessage: saved, to: book.id) {
            toast = Toast(text: "Forwarded to \(book.title)", systemImage: "arrowshape.turn.up.right.fill")
        } else {
            errorMessage = "The message wasn't forwarded. Check your connection and try again."
        }
    }
}

private struct ViewedMedia: Identifiable {
    enum Kind { case photo, video }
    let id = UUID()
    let url: URL
    let kind: Kind
}

// MARK: - Forward destination picker

// Every book chat in every club the user belongs to, grouped by club (current read first — the
// same ordering as the Share extension), with the chat this sheet was opened from pinned on top.
// Picking one asks for confirmation before anything is sent.
private struct ForwardPickerSheet: View {
    let currentBook: Book
    let onForward: (Book) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sections: [(club: String, books: [Book])] = []
    @State private var loading = true
    @State private var loadFailed = false
    @State private var confirming: Book?

    var body: some View {
        NavigationView {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if loadFailed {
                    Text("Couldn't load your chats.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section("This chat") { bookRow(currentBook) }
                        ForEach(sections, id: \.club) { section in
                            Section(section.club) {
                                ForEach(section.books) { bookRow($0) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Forward to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog(
                confirming.map { "Forward to \($0.title)?" } ?? "",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible
            ) {
                if let book = confirming {
                    Button("Forward") { onForward(book) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .task { await load() }
    }

    private func bookRow(_ book: Book) -> some View {
        Button { confirming = book } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).foregroundColor(.primary)
                Text(book.author).font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("forwardTo-\(book.title)")
    }

    private func load() async {
        defer { loading = false }
        do {
            async let clubsCall = APIClient.shared.getMyClubs()
            async let booksCall = APIClient.shared.getMyBooks()
            let (clubs, books) = try await (clubsCall, booksCall.books)
            let byId = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let plan = SharePlan.sections(
                books: books.filter { $0.id != currentBook.id }.map {
                    ShareBook(id: $0.id, clubId: $0.clubId, title: $0.title, author: $0.author, status: $0.status.rawValue)
                },
                clubs: clubs.map { ShareClub(id: $0.id, name: $0.name) }
            )
            sections = plan.map { section in
                (club: section.name, books: section.books.compactMap { byId[$0.id] })
            }
        } catch {
            loadFailed = true
        }
    }
}

// MARK: - Text detail

private struct SavedTextDetail: View {
    let saved: SavedMessage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(saved.senderName).font(.caption).foregroundColor(.secondary)
                Text(saved.body ?? "")
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(saved.sentAt, style: .date).font(.caption2).foregroundColor(Color(.tertiaryLabel))
            }
            .padding()
        }
        .navigationTitle("Saved Message")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    UIPasteboard.general.string = saved.body
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
    }
}

// MARK: - Row

private struct SavedMessageRow: View {
    let saved: SavedMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(saved.isDeleted ? "Deleted message" : saved.senderName)
                .font(.caption)
                .foregroundColor(.secondary)
            contentPreview
            Text(saved.sentAt, style: .date)
                .font(.caption2)
                .foregroundColor(Color(.tertiaryLabel))
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var contentPreview: some View {
        if saved.isDeleted {
            Text("This message was deleted")
                .font(.subheadline)
                .italic()
                .foregroundColor(.secondary)
        } else {
            switch saved.type {
            case .text:
                Text(saved.body ?? "")
                    .font(.subheadline)
                    .lineLimit(3)
            case .photo:
                if let urlStr = saved.mediaUrl, let url = URL(string: urlStr) {
                    CachedRemoteImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(height: 120)
                                .frame(maxWidth: .infinity)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else if phase.isError {
                            Label("Photo unavailable", systemImage: "photo")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else {
                            ProgressView().frame(height: 80)
                        }
                    }
                } else {
                    Label("Photo", systemImage: "photo")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            case .voice:
                if let urlStr = saved.mediaUrl, let url = URL(string: urlStr) {
                    SavedVoicePreview(url: url, duration: saved.durationSeconds ?? 0)
                } else {
                    Label(formatDuration(saved.durationSeconds ?? 0), systemImage: "waveform")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            case .video:
                Label("Video — tap to play", systemImage: "play.rectangle")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            case .unknown:
                EmptyView()
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// Plays a saved voice message in place, at the same speed the chat uses (the bunny here shares
// AudioPlayerService's persisted rate, so changing it here changes it everywhere).
private struct SavedVoicePreview: View {
    let url: URL
    let duration: Int
    @ObservedObject private var audio = AudioPlayerService.shared
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var showSpeed = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                togglePlay()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("savedVoicePlay")

            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: "waveform")
                    .foregroundColor(.accentColor)
                Text(formatDuration(duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button { showSpeed.toggle() } label: {
                BunnySpeedIcon(speed: audio.playbackRate)
                    .foregroundColor(.accentColor)
                    .frame(minWidth: 36, minHeight: 36)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Playback speed")
            .popover(isPresented: $showSpeed) {
                VerticalSpeedSlider(rate: audio.playbackRate) { rate in
                    audio.setRate(rate)
                    if isPlaying { player?.rate = audio.playbackRate }
                }
                .popoverCompactAdaptation()
            }
        }
        .padding(.vertical, 4)
        .onDisappear { player?.pause() }
    }

    private func togglePlay() {
        if player == nil {
            let item = AVPlayerItem(url: url)
            player = AVPlayer(playerItem: item)
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                isPlaying = false
                player?.seek(to: .zero)
            }
        }
        if isPlaying {
            player?.pause()
        } else {
            // Finalize-and-send any in-progress recording before claiming AVAudioSession for
            // playback — the two silently fight over the shared session otherwise (#160).
            AudioRecorder.forceStopForPlayback?()
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            player?.playImmediately(atRate: audio.playbackRate)
        }
        isPlaying.toggle()
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
