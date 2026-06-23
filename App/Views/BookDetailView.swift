import SwiftUI
import UIKit
import AVKit
import AVFoundation
import Speech
import UserNotifications

struct BookDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: BookViewModel
    @ObservedObject private var deepLink = DeepLinkCoordinator.shared
    // Observed so the title's unread (unheard-voice) count updates live as messages
    // are played / marked heard.
    @ObservedObject private var playbackStore = PlaybackProgressStore.shared
    // Observed so the reply banner's voice transcript appears when it finishes.
    @ObservedObject private var transcripts = TranscriptStore.shared
    @State private var showingDeleteConfirm = false
    @State private var showingDetails = false
    @AppStorage("tapToTalkEnabled") private var tapToTalk = false
    // Tracks rows currently rendered by LazyVStack (slight superset of the visible
    // viewport since LazyVStack keeps a small buffer). Used only to auto-dismiss
    // the "New message" pill once the user can see the newest message.
    @State private var visibleMessageIds: Set<UUID> = []
    @State private var keyboardVisible: Bool = false
    @State private var hasUnseenMessage: Bool = false
    @State private var lastSeenNewestId: UUID? = nil
    // The message a tapped notification was for. Set on chat open; cleared once
    // we've scrolled to it. Lets us jump straight to the tapped message (and warm
    // its audio) instead of parking on "newest cached" and showing the pill.
    @State private var targetMessageId: UUID? = nil
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
                            // Top sentinel for pagination. Becomes visible only when
                            // the user scrolls to the top of the rendered window; its
                            // .onAppear triggers loadOlderMessages. The view model
                            // guards against re-entry and terminal state, so repeated
                            // scrolls back and forth are safe.
                            if viewModel.reachedBeginning {
                                Text("Beginning of discussion")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 12)
                            } else {
                                HStack {
                                    Spacer()
                                    if viewModel.isLoadingOlderMessages {
                                        ProgressView()
                                    } else {
                                        Color.clear.frame(height: 1)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 12)
                                .onAppear { Task { await viewModel.loadOlderMessages() } }
                            }
                            ForEach(viewModel.visibleMessages.reversed()) { message in
                                MessageRow(message: message, viewModel: viewModel, onJumpToParent: { parentId in
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        proxy.scrollTo(parentId, anchor: .center)
                                    }
                                })
                                    .id(message.id)
                                    .onAppear { visibleMessageIds.insert(message.id) }
                                    .onDisappear { visibleMessageIds.remove(message.id) }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    // Tap anywhere in the chat dismisses the keyboard. simultaneousGesture
                    // fires ALONGSIDE child gestures (not on top of them), so it catches
                    // taps on empty space yet still lets a long-press open the Reply menu
                    // and a tap on a bubble play it — and it never blocks scrolling.
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            if keyboardVisible { dismissKeyboard() }
                        }
                    )
                    .overlay(alignment: .bottom) {
                        // "New message" pill: surfaces when somebody else's message
                        // arrives while the user is in the chat (possibly mid-playback
                        // of audio/video, or looking at an image). Tap to jump to it.
                        if hasUnseenMessage {
                            Button {
                                if let newest = viewModel.visibleMessages.first {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        proxy.scrollTo(newest.id, anchor: .bottom)
                                    }
                                    hasUnseenMessage = false
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down")
                                    Text("New message")
                                        .font(.caption.weight(.semibold))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                                .shadow(radius: 2, y: 1)
                            }
                            .padding(.bottom, 12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    // Always scroll to newest on entry. Multiple attempts handle the
                    // cache→fresh-fetch transition and the LazyVStack layout-pass timing.
                    .task(id: viewModel.book.id) {
                        // Arrived via a notification tap (fresh open)? Capture (and
                        // consume) the targeted message so we can jump straight to it.
                        if let target = deepLink.pendingMessageId,
                           deepLink.pendingMessageBookId == viewModel.book.id {
                            targetMessageId = target
                            deepLink.pendingMessageId = nil
                            deepLink.pendingMessageBookId = nil
                        }
                        let delaysMs: [UInt64] = [0, 50, 150, 400, 1000]
                        for delay in delaysMs {
                            if delay > 0 { try? await Task.sleep(for: .milliseconds(Int(delay))) }
                            // Prefer the tapped message once it's loaded; until then keep
                            // newest in view (the new message often isn't cached yet).
                            if let target = targetMessageId,
                               viewModel.visibleMessages.contains(where: { $0.id == target }) {
                                focusMessage(target, proxy: proxy)
                                targetMessageId = nil
                                hasUnseenMessage = false
                            } else if let newest = viewModel.visibleMessages.first {
                                proxy.scrollTo(newest.id, anchor: .bottom)
                            }
                        }
                        lastSeenNewestId = viewModel.visibleMessages.first?.id
                    }
                    // New message arrived. Two cases:
                    //   - Your own send (optimistic insert OR server echo) → scroll, no pill.
                    //     You want to see what you sent.
                    //   - Anyone else → show the pill, do NOT yank. Audio/video playback,
                    //     reading, image preview all continue uninterrupted.
                    .onChange(of: viewModel.visibleMessages.first?.id) { newId in
                        guard let newId else { return }
                        if lastSeenNewestId == nil { lastSeenNewestId = newId; return }
                        if lastSeenNewestId == newId { return }
                        // Still chasing the notification's message and it just loaded?
                        // Go straight to it — no pill.
                        if let target = targetMessageId,
                           viewModel.visibleMessages.contains(where: { $0.id == target }) {
                            focusMessage(target, proxy: proxy)
                            targetMessageId = nil
                            hasUnseenMessage = false
                            lastSeenNewestId = newId
                            return
                        }
                        let newest = viewModel.visibleMessages.first
                        let isMine = newest?.senderId == TokenStore.shared.userId
                        if isMine {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(newId, anchor: .bottom)
                            }
                            hasUnseenMessage = false
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) {
                                hasUnseenMessage = true
                            }
                        }
                        lastSeenNewestId = newId
                    }
                    // Once the newest message becomes visible (user scrolled down,
                    // tapped the pill, etc.) auto-dismiss the pill.
                    .onChange(of: visibleMessageIds.contains(viewModel.visibleMessages.first?.id ?? UUID())) { atBottom in
                        if atBottom, hasUnseenMessage {
                            withAnimation(.easeOut(duration: 0.2)) {
                                hasUnseenMessage = false
                            }
                        }
                    }
                    // Notification tap while this chat is ALREADY on screen: .task(id:)
                    // doesn't re-fire, so react to the published target directly. The
                    // tapped message usually hasn't loaded yet (sent while backgrounded);
                    // we adopt it as the target and the visibleMessages observer below
                    // focuses it the moment it arrives (foreground refresh / SignalR).
                    .onChange(of: deepLink.pendingMessageId) { mid in
                        guard let mid, deepLink.pendingMessageBookId == viewModel.book.id else { return }
                        targetMessageId = mid
                        deepLink.pendingMessageId = nil
                        deepLink.pendingMessageBookId = nil
                        if viewModel.visibleMessages.contains(where: { $0.id == mid }) {
                            focusMessage(mid, proxy: proxy)
                            targetMessageId = nil
                            hasUnseenMessage = false
                        }
                    }
                    // Fallback for a tap whose push carried no messageId (e.g. older
                    // notifications): just bring newest into view, no targeting.
                    .onChange(of: deepLink.pendingBookId) { pending in
                        guard pending == viewModel.book.id else { return }
                        deepLink.pendingBookId = nil
                        guard targetMessageId == nil, deepLink.pendingMessageId == nil,
                              let newest = viewModel.visibleMessages.first else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(newest.id, anchor: .bottom)
                        }
                    }
                    // Keep the currently-playing voice message in focus. Autoplay
                    // advances through voice messages chronologically; if the next one is
                    // below the fold, bring it into view so audio never plays for an
                    // off-screen bubble. Fires only when the playing message changes (not
                    // on progress ticks), and only scrolls when it isn't already visible
                    // so it never yanks a bubble that's already on screen.
                    .onReceive(AudioPlayerService.shared.$playingMessageId) { playingId in
                        guard let playingId, !visibleMessageIds.contains(playingId) else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(playingId, anchor: .center)
                        }
                    }
                }
            }

            if let typing = viewModel.typingIndicator {
                Text(typing)
                    .font(.body)
                    .italic()
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .transition(.opacity)
            }

            if let reply = viewModel.replyingTo {
                HStack(spacing: 8) {
                    Rectangle().fill(Color.accentColor).frame(width: 3, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replying to \(reply.senderName) · \(formatMessageDate(reply.sentAt))")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.accentColor)
                        Text(replyBannerPreview(reply))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button { viewModel.replyingTo = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(.systemGray6))
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
        .animation(.easeInOut(duration: 0.2), value: viewModel.typingIndicator)
        .onChange(of: viewModel.messageText) { _ in viewModel.notifyTyping() }
        .navigationTitle(unheardVoiceMessages.isEmpty ? viewModel.book.title : "\(viewModel.book.title) (\(unheardVoiceMessages.count))")
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
        .sheet(isPresented: $showingDetails) {
            BookDetailsView(book: viewModel.book)
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
            // Report the voice message as heard (sticky, server-side) for receipts + unread.
            AudioPlayerService.shared.onPlaybackCompleted = { [weak viewModel] completedId in
                guard let vm = viewModel else { return }
                Task { try? await APIClient.shared.markHeard(bookId: vm.book.id, messageId: completedId) }
            }
            // Auto-advance to the next (newer) voice message in the chat, if any.
            AudioPlayerService.shared.nextToPlay = { [weak viewModel] completedId in
                guard let vm = viewModel else { return nil }
                let voices = vm.visibleMessages.filter { $0.type == .voice && !$0.isDeleted }
                guard let idx = voices.firstIndex(where: { $0.id == completedId }), idx > 0 else { return nil }
                return voices[idx - 1]
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
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
        .onDisappear {
            viewModel.disconnect()
            // Stop voice playback when actually leaving the chat (this fires on a real
            // navigation pop, not when a bubble merely scrolls out of view).
            AudioPlayerService.shared.stopAll()
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func replyBannerPreview(_ m: Message) -> String {
        switch m.type {
        case .text: return m.body ?? ""
        case .voice:
            if let t = transcripts.text(for: m.id), !t.isEmpty { return "🎤 \(t)" }
            return "🎤 Voice message"
        case .photo: return "📷 Photo"
        case .video: return "🎬 Video"
        case .unknown: return ""
        }
    }

    // Loaded voice messages from OTHERS not yet marked played (drives the chat-title
    // unread count + "Mark all as heard"). Excludes your own — you can't have an
    // "unheard" message you sent — matching the server's unread definition.
    private var unheardVoiceMessages: [Message] {
        viewModel.visibleMessages.filter {
            $0.type == .voice && !$0.isDeleted
                && $0.senderId != TokenStore.shared.userId
                && !PlaybackProgressStore.shared.isCompleted($0.id)
        }
    }

    @ViewBuilder
    private var bookMenuItems: some View {
        Button { showingDetails = true } label: {
            Label("Details", systemImage: "info.circle")
        }
        Divider()
        if !unheardVoiceMessages.isEmpty {
            Button {
                PlaybackProgressStore.shared.markHeard(
                    unheardVoiceMessages.map { (id: $0.id, duration: $0.durationSeconds ?? 0) }
                )
                Task { try? await APIClient.shared.markAllHeard(bookId: viewModel.book.id) }
            } label: {
                Label("Mark all as heard", systemImage: "checkmark.circle")
            }
            Divider()
        }
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

    // Scroll to a specific message (the one a notification was tapped for) and, if it's
    // a voice message, warm its audio into AudioCache so the first tap plays instantly.
    private func focusMessage(_ id: UUID, proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(id, anchor: .bottom)
        }
        guard let msg = viewModel.visibleMessages.first(where: { $0.id == id }),
              msg.type == .voice, let urlStr = msg.mediaUrl, let url = URL(string: urlStr) else { return }
        AudioCache.shared.prefetch(url)
    }
}

struct MessageRow: View {
    let message: Message
    @ObservedObject var viewModel: BookViewModel
    @ObservedObject private var transcripts = TranscriptStore.shared
    var onJumpToParent: (UUID) -> Void = { _ in }
    @State private var showFullScreen = false
    @State private var showSenderProfile = false
    @State private var profileReader: APIClient.ChatReadDto?
    @State private var safariItem: SafariItem?
    @State private var showEditSheet = false
    @State private var editText = ""
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
                    if let parentId = message.parentMessageId {
                        replyChip(parentId: parentId)
                    }
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
        .sheet(item: $safariItem) { SafariView(url: $0.url) }
        .sheet(isPresented: $showEditSheet) {
            EditMessageSheet(text: $editText) { newBody in
                Task { await viewModel.editMessage(id: message.id, newBody: newBody) }
            }
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
                    viewModel.replyingTo = message
                    if message.type == .voice {
                        TranscriptStore.shared.transcribeIfNeeded(messageId: message.id, mediaUrlString: message.mediaUrl)
                    }
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                if message.type == .text, let body = message.body, !body.isEmpty {
                    Button {
                        UIPasteboard.general.string = body
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    if isMe {
                        Button {
                            editText = body
                            showEditSheet = true
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                    }
                }
                if message.type == .voice, !PlaybackProgressStore.shared.isCompleted(message.id) {
                    Button {
                        PlaybackProgressStore.shared.markHeard([(id: message.id, duration: message.durationSeconds ?? 0)])
                        Task { try? await APIClient.shared.markHeard(bookId: viewModel.book.id, messageId: message.id) }
                    } label: {
                        Label("Mark as Heard", systemImage: "checkmark.circle")
                    }
                }
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

    // Quoted preview of the message this one is replying to. Tap to jump to it. For a
    // voice parent, show the on-device transcript ("🎤 first words…") once available;
    // until then the server's "🎤 Voice message" label.
    private func replyChip(parentId: UUID) -> some View {
        let preview: String = {
            if let t = transcripts.text(for: parentId), !t.isEmpty { return "🎤 \(t)" }
            return message.parentPreview ?? ""
        }()
        return Button { onJumpToParent(parentId) } label: {
            HStack(spacing: 6) {
                Rectangle().fill(Color.accentColor).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(message.parentSenderName ?? "Reply")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.accentColor)
                        if let ts = message.parentSentAt {
                            Text(formatMessageDate(ts))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Text(preview)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 240, alignment: .leading)
        }
        .buttonStyle(.plain)
        .onAppear {
            // Best-effort: if the parent is a loaded voice message, transcribe it.
            if let parent = viewModel.messages.first(where: { $0.id == parentId }), parent.type == .voice {
                TranscriptStore.shared.transcribeIfNeeded(messageId: parentId, mediaUrlString: parent.mediaUrl)
            }
        }
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            )
    }

    @ViewBuilder
    private var readReceiptRow: some View {
        // Every message the reader has seen (their last-seen message or any newer one)
        // shows their avatar — not just the single message that is their exact frontier.
        let readers = viewModel.readers(of: message)
        Group {
            if !readers.isEmpty {
                HStack(spacing: 4) {
                    Spacer()
                    Text("Read by")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    ForEach(readers, id: \.userId) { reader in
                        Button { profileReader = reader } label: {
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
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .sheet(item: $profileReader) { reader in
                    SenderProfileView(
                        senderId: reader.userId,
                        senderName: reader.displayName,
                        avatarUrl: reader.avatarUrl
                    )
                }
            }
        }
    }

    // Detect URLs in a plain message body and mark them as tappable links. Uses
    // NSDataDetector (not LocalizedStringKey markdown, which would misread stray
    // */_ in messages). The .link attribute makes SwiftUI render + tap them; the
    // openURL override on the bubble decides where they open.
    private func linkified(_ string: String) -> AttributedString {
        var attributed = AttributedString(string)
        guard !string.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return attributed }
        let nsRange = NSRange(string.startIndex..<string.endIndex, in: string)
        for match in detector.matches(in: string, options: [], range: nsRange) {
            guard let url = match.url,
                  let strRange = Range(match.range, in: string),
                  let lower = AttributedString.Index(strRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(strRange.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].link = url
            attributed[lower..<upper].underlineStyle = .single
        }
        return attributed
    }

    @ViewBuilder
    private var messageBubble: some View {
        switch message.type {
        case .text:
            Text(linkified(message.body ?? ""))
                .tint(isMe ? .white : .blue)   // link color on blue vs grey bubbles
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isMe ? Color.myMessageBlue : Color(.systemGray5))
                .foregroundColor(isMe ? .white : .primary)
                .cornerRadius(16)
                // Tapping a detected link opens web URLs in an in-app Safari sheet;
                // mailto:/tel:/etc. fall through to the system handler.
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "http" || url.scheme == "https" {
                        safariItem = SafariItem(url: url)
                        return .handled
                    }
                    return .systemAction
                })

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
                bookId: viewModel.book.id,
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

// Soft, slightly muted "my message" blue shared by text + voice bubbles and the voice
// play icon (the vivid system blue read too harsh against the white play chip).
extension Color {
    static let myMessageBlue = Color(red: 0.38, green: 0.55, blue: 0.80)
    // Slightly dimmed white for the "my" play chip + progress bar/dot, so they don't
    // irradiate against the blue bubble and read as oversized.
    static let softWhite = Color(white: 0.90)
}

// Simple multiline editor for editing a sent text message.
struct EditMessageSheet: View {
    @Binding var text: String
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .padding(12)
                .navigationTitle("Edit Message")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { onSave(text); dismiss() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}

struct VoiceMessageBubble: View {
    let message: Message
    let isMe: Bool
    var bookId: UUID
    var onRetry: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    @ObservedObject private var audio = AudioPlayerService.shared
    @ObservedObject private var store = PlaybackProgressStore.shared
    @GestureState private var isScrubbing = false
    @State private var showTranscription = false
    @State private var transcription: String?
    @State private var isTranscribing = false

    private var isPlaying: Bool { audio.playingMessageId == message.id }
    private var isSending: Bool { message.sendState == .sending }
    private var isFailed: Bool { message.sendState == .failed }
    private var totalSeconds: Int { message.durationSeconds ?? 0 }
    // Fully listened: the play circle goes green once the audio has reached the end.
    // Clears on replay (AudioPlayerService clears the completed flag when it restarts).
    private var isFullyPlayed: Bool { store.isCompleted(message.id) }
    // The "my message" blue — softer/muted vs the vivid system blue. Shared by the
    // bubble and the play icon so they read as one color family.
    private var myBlue: Color { .myMessageBlue }

    // All three play/pause controls share one circle "chip" of the same size: a light
    // chip with a dark/accent icon. White chip on own (blue) bubbles and while playing
    // (black bubble); grey chip on others' (grey) bubbles.
    private var chipBackground: Color {
        if isPlaying { return .white }
        // Soft white (not pure white) on own bubbles so the chip doesn't irradiate
        // against the blue and read as oversized; the others' chip is darker than its
        // grey bubble by a comparable amount so both read as the same visual weight.
        return isMe ? .softWhite : Color(.systemGray2)
    }
    private var chipIconColor: Color {
        if isPlaying { return .black }
        return isMe ? myBlue : Color(.darkGray)
    }
    // Live position while playing; otherwise the persisted resume position.
    private var displayFraction: Double {
        if isPlaying { return audio.progress }
        guard totalSeconds > 0 else { return 0 }
        return min(store.position(for: message.id) / Double(totalSeconds), 1)
    }
    // Progress bar / thumb color, matched to the play control: white while playing
    // (black bubble) and on own (blue) bubbles, dark grey on others' (grey) bubbles.
    private var barColor: Color {
        if isPlaying { return .white }
        return isMe ? .softWhite : Color(.darkGray)
    }

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
        // Softer, slightly muted blue (vs the vivid system blue) so the white play
        // chip doesn't contrast so hard that the control looks oversized.
        .background(isPlaying ? Color.black : (isMe ? myBlue : Color(.systemGray5)))
        .foregroundColor(isPlaying || isMe ? .white : .primary)
        .cornerRadius(16)
        .frame(maxWidth: isPlaying || showTranscription ? .infinity : 180)
        .animation(.easeInOut(duration: 0.25), value: isPlaying)
        .animation(.easeInOut(duration: 0.2), value: showTranscription)
        // NOTE: deliberately no onDisappear-pause here. The bubble disappears whenever
        // it scrolls out of the LazyVStack, and pausing on that stopped playback when
        // the user scrolled away. Stopping playback on leaving the chat is handled by
        // the chat view's own onDisappear instead.
        .onAppear {
            // Warm the audio cache as a bubble scrolls into view, so tapping play is
            // instant. No-op if already cached / not a remote URL.
            if let urlStr = message.mediaUrl, let url = URL(string: urlStr) {
                AudioCache.shared.prefetch(url)
            }
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
                Button { audio.toggle(message: message, bookId: bookId) } label: {
                    Group {
                        if isPlaying && audio.isBuffering {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(chipIconColor)
                                // play.fill sits optically left of center; nudge right so it
                                // centers in the chip. pause is symmetric, so no offset.
                                .offset(x: isPlaying ? 0 : 1.5)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(chipBackground)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    let frac = displayFraction
                    let thumb: CGFloat = isScrubbing ? 20 : 14
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(isPlaying ? Color.white.opacity(0.3) : (isMe ? Color.white.opacity(0.35) : Color(.systemGray3)))
                            .frame(height: 6)
                        Capsule()
                            .fill(barColor)
                            .frame(width: geo.size.width * frac, height: 6)
                        // Draggable position indicator — shows the live position while
                        // playing and the persisted resume point on idle bubbles.
                        Circle()
                            .fill(isFullyPlayed ? .green : barColor)   // green once fully listened to
                            .frame(width: thumb, height: thumb)
                            .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                            .offset(x: min(max(geo.size.width * frac - thumb / 2, 0), geo.size.width - thumb))
                            .animation(.easeOut(duration: 0.12), value: isScrubbing)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($isScrubbing) { _, state, _ in state = true }
                            .onChanged { value in
                                let f = max(0, min(1, value.location.x / geo.size.width))
                                if isPlaying {
                                    audio.seek(to: f)            // live scrub
                                } else {
                                    store.setPosition(id: message.id, fraction: f, duration: totalSeconds)
                                }
                            }
                    )
                }
                .frame(height: 28)

                Text(formatDuration(isPlaying ? audio.currentSeconds : totalSeconds))
                    .font(.caption2)
                    .monospacedDigit()
            }

            if isPlaying {
                Button { audio.cycleRate() } label: {
                    BunnySpeedIcon(speed: audio.playbackRate)
                        .frame(width: 44, height: 44)
                }

                RoutePickerView(tintColor: .white)   // only shown while playing (black bubble)
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
        // Cache it so a reply quoting this voice message can show the transcript too.
        if let t = transcription, !t.isEmpty {
            TranscriptStore.shared.store(t, for: message.id)
        }
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
                if let cached = await ImageCache.shared.get(url) { avatarImage = cached; return }
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
