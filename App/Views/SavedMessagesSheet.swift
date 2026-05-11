import SwiftUI
import AVKit

struct SavedMessagesSheet: View {
    @ObservedObject var viewModel: BookViewModel

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
                            SavedMessageRow(saved: saved)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Task { await viewModel.forwardMessage(savedMessage: saved) }
                                }
                        }
                        .onDelete { offsets in
                            let items = offsets.map { viewModel.savedMessages[$0] }
                            for item in items {
                                Task { await viewModel.unsaveSavedMessage(savedMessage: item) }
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
        .task { await viewModel.loadSavedMessages() }
    }
}

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
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(height: 120)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        case .failure:
                            Label("Photo unavailable", systemImage: "photo")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        case .empty:
                            ProgressView().frame(height: 80)
                        @unknown default:
                            EmptyView()
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
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct SavedVoicePreview: View {
    let url: URL
    let duration: Int
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                togglePlay()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: "waveform")
                    .foregroundColor(.accentColor)
                Text(formatDuration(duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
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
            ) { _ in isPlaying = false }
        }
        if isPlaying {
            player?.pause()
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            player?.play()
        }
        isPlaying.toggle()
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
