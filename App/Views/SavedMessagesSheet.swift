import SwiftUI

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
        VStack(alignment: .leading, spacing: 4) {
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
                    .lineLimit(2)
            case .photo:
                Label("Photo", systemImage: "photo")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            case .voice:
                Label(formatDuration(saved.durationSeconds ?? 0), systemImage: "waveform")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
