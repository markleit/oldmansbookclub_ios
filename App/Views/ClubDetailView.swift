import SwiftUI

struct ClubDetailView: View {
    @StateObject private var viewModel: ClubViewModel
    @State private var showingCreateEvent = false

    init(club: Club) {
        _viewModel = StateObject(wrappedValue: ClubViewModel(club: club))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Message history
            if viewModel.isLoadingMessages {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.messages.isEmpty {
                Text("No messages yet. Say hello!")
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

            // Message input (read-only until SignalR is wired up)
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
        .navigationTitle(viewModel.club.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .onDisappear { Task { await viewModel.disconnect() } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingCreateEvent = true } label: {
                    Image(systemName: "calendar.badge.plus")
                }
            }
        }
        .sheet(isPresented: $showingCreateEvent) {
            CreateEventView(clubId: viewModel.club.id) { _ in }
        }
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

struct ClubDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ClubDetailView(club: Club(id: UUID(), name: "Sample Club", description: "A short description."))
        }
    }
}
