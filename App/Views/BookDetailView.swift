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
    // Observed so voice bubbles re-render live as messages are played / marked heard.
    @ObservedObject private var playbackStore = PlaybackProgressStore.shared
    @ObservedObject private var heardStore = HeardStore.shared
    // Single source of truth for the unread count shown in the title (same value the
    // club-view + icon badges use).
    @ObservedObject private var unreadStore = UnreadStore.shared
    // Observed so the reply banner's voice transcript appears when it finishes.
    @ObservedObject private var transcripts = TranscriptStore.shared
    @State private var showingDeleteConfirm = false
    // #58: deleting a book is destructive (removes all its messages, unrecoverable), so we
    // require the user to type the book's title to confirm — accidental taps can't delete.
    @State private var deleteConfirmText = ""
    // Forgiving match for the delete-confirmation: trims surrounding whitespace and ignores
    // case so the confirmation isn't frustrating, while still requiring a deliberate action.
    private func titleMatches(_ typed: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(viewModel.book.title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
    @State private var showingDetails = false
    @State private var showingEdit = false
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
    var onUpdated: ((Book) -> Void)?

    init(book: Book, onDeleted: (() -> Void)? = nil, onStatusChanged: ((BookStatus) -> Void)? = nil, onUpdated: ((Book) -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: BookViewModel(book: book))
        self.onDeleted = onDeleted
        self.onStatusChanged = onStatusChanged
        self.onUpdated = onUpdated
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
        .navigationTitle({ let n = unreadStore.counts[viewModel.book.id] ?? 0
            return n == 0 ? viewModel.book.title : "\(viewModel.book.title) (\(n))" }())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu { bookMenuItems } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Delete \"\(viewModel.book.title)\"?", isPresented: $showingDeleteConfirm) {
            TextField("Type the book title", text: $deleteConfirmText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { deleteConfirmText = "" }
            Button("Delete", role: .destructive) {
                let text = deleteConfirmText
                deleteConfirmText = ""
                guard titleMatches(text) else { return }
                Task {
                    try? await viewModel.deleteBook()
                    onDeleted?()
                    dismiss()
                }
            }
            .disabled(!titleMatches(deleteConfirmText))
        } message: {
            Text("This permanently deletes the book and all of its messages. This can't be undone.\n\nType the book title to confirm.")
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
        .sheet(isPresented: $showingEdit) {
            AddBookView(clubId: viewModel.book.clubId, editingBook: viewModel.book) { updated in
                viewModel.applyEdit(updated)
                onUpdated?(updated)
            }
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
                Task { @MainActor in vm.consumeHeard([completedId]) }
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

    @ViewBuilder
    private var bookMenuItems: some View {
        Button { showingDetails = true } label: {
            Label("Details", systemImage: "info.circle")
        }
        Button { showingEdit = true } label: {
            Label("Edit Book", systemImage: "pencil")
        }
        Divider()
        if (unreadStore.counts[viewModel.book.id] ?? 0) > 0 {
            Button {
                // Mark every type consumed: voice → heard, text/photo/video → read (advance
                // last-seen to newest). Local first so the count zeroes instantly, then the
                // outbox sends both — and a failure stays queued rather than being lost (#119).
                let unheard = viewModel.unheardVoiceMessages
                PlaybackProgressStore.shared.markHeard(
                    unheard.map { (id: $0.id, duration: $0.durationSeconds ?? 0) }
                )
                HeardStore.shared.markHeard(unheard.map(\.id), bookId: viewModel.book.id)
                UnreadStore.shared.zero(bookId: viewModel.book.id)
                let latestId = viewModel.visibleMessages.first(where: { $0.sendState == nil })?.id
                Task {
                    await ReceiptQueue.shared.markAllHeard(bookId: viewModel.book.id)
                    if let latestId {
                        await ReceiptQueue.shared.markRead(bookId: viewModel.book.id, messageId: latestId)
                    }
                }
            } label: {
                Label("Mark all as read", systemImage: "checkmark.circle")
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
        Button("Delete Book", role: .destructive) {
            deleteConfirmText = ""
            showingDeleteConfirm = true
        }
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
    @State private var showReactionsPopup = false   // #47 — tap a pill to see who reacted
    @State private var showReactMenu = false        // #47 — long-press reaction + action menu
    @State private var showEmojiPicker = false      // #145 — "+" on the reaction bar, any emoji
    private var isMe: Bool { message.senderId == TokenStore.shared.userId }

    // #47 — the fixed reaction set.
    static let reactionEmojis = ["👍", "❤️", "😂", "😮", "😢", "🎉"]

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
                        .overlay(alignment: isMe ? .topLeading : .topTrailing) {
                            // iMessage-style: reaction badge overlaps the bubble's outer top
                            // corner (top-right for received, top-left for your own).
                            reactionPills.offset(x: isMe ? -6 : 6, y: -12)
                        }
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
        // #47 — custom long-press menu: horizontal reaction bar on top, actions below (native
        // .contextMenu can't do a horizontal row). highPriorityGesture gives the hold priority
        // over interactive children (voice scrubber, transcription tap) and SUPPRESSES their
        // action when the picker fires — so a hold only opens the menu. A quick tap still hits
        // the child (< 0.4s), and a drag still scrubs (long-press cancels on finger-move).
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in
                    guard message.sendState == .failed || (!message.isDeleted && message.sendState == nil) else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showReactMenu = true
                }
        )
        .popover(isPresented: $showReactMenu) { reactionActionMenu }
        .sheet(isPresented: $showEmojiPicker) {
            EmojiPickerSheet { emoji in
                viewModel.toggleReaction(String(emoji), on: message)
            }
        }
    }

    // MARK: - #47 long-press reaction + action menu

    @ViewBuilder
    private var reactionActionMenu: some View {
        let menu = VStack(alignment: .leading, spacing: 0) {
            if !message.isDeleted && message.sendState == nil {
                HStack(spacing: 6) {
                    ForEach(MessageRow.reactionEmojis, id: \.self) { emoji in
                        Button {
                            showReactMenu = false
                            viewModel.toggleReaction(emoji, on: message)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 26))
                                .frame(width: 42, height: 42)
                                .background(
                                    message.myReactionEmoji == emoji ? Color.accentColor.opacity(0.25) : Color.clear,
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    // #145 — any other emoji, via the system Emoji keyboard.
                    Button {
                        showReactMenu = false
                        showEmojiPicker = true
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 22))
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("addEmojiReactionButton")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }
            actionMenuButtons
        }
        .frame(minWidth: 250)

        if #available(iOS 16.4, *) {
            menu.presentationCompactAdaptation(.popover)
        } else {
            menu
        }
    }

    @ViewBuilder
    private var actionMenuButtons: some View {
        if message.sendState == .failed {
            // #146 — text now reaches .failed too (previously only media could); route by type.
            if message.type == .text {
                menuRow("Retry", "arrow.clockwise") { Task { await viewModel.retryTextMessage(id: message.id) } }
                menuRow("Cancel", "xmark", destructive: true) { viewModel.cancelTextMessage(id: message.id) }
            } else {
                menuRow("Retry", "arrow.clockwise") { Task { await viewModel.retryMediaMessage(id: message.id) } }
                menuRow("Cancel", "xmark", destructive: true) { viewModel.cancelMediaMessage(id: message.id) }
            }
        } else if !message.isDeleted && message.sendState == nil {
            menuRow("Reply", "arrowshape.turn.up.left") {
                viewModel.replyingTo = message
                if message.type == .voice {
                    TranscriptStore.shared.transcribeIfNeeded(messageId: message.id, mediaUrlString: message.mediaUrl)
                }
            }
            if message.type == .text, let body = message.body, !body.isEmpty {
                menuRow("Copy", "doc.on.doc") { UIPasteboard.general.string = body }
                if isMe {
                    // Defer the edit sheet until the popover has dismissed (#50).
                    menuRow("Edit", "pencil") { editText = body; DispatchQueue.main.async { showEditSheet = true } }
                }
            }
            if message.type == .voice, !HeardStore.shared.isHeard(message.id) {
                menuRow("Mark as Heard", "checkmark.circle") {
                    PlaybackProgressStore.shared.markHeard([(id: message.id, duration: message.durationSeconds ?? 0)])
                    viewModel.consumeHeard([message.id])
                }
            }
            menuRow("Save", "bookmark") { Task { await viewModel.saveMessage(id: message.id) } }
            if isMe {
                menuRow("Delete", "trash", destructive: true) { Task { await viewModel.deleteMessage(id: message.id) } }
            } else {
                menuRow("Report", "flag") { Task { await viewModel.reportMessage(id: message.id) } }
                menuRow("Block User", "hand.raised", destructive: true) { Task { await viewModel.blockUser(senderId: message.senderId) } }
            }
        }
    }

    private func menuRow(_ title: String, _ icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            showReactMenu = false
            action()
        } label: {
            Label(title, systemImage: icon)
                .foregroundStyle(destructive ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    // #47 — reaction pills under the bubble: emoji + count, mine highlighted; tap to see who.
    @ViewBuilder
    private var reactionPills: some View {
        let tallies = message.reactionTallies
        if !tallies.isEmpty {
            HStack(spacing: 4) {
                ForEach(tallies) { t in
                    Button { showReactionsPopup = true } label: {
                        HStack(spacing: 3) {
                            Text(t.emoji).font(.system(size: 13))
                            Text("\(t.count)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(t.mine ? .white : .secondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(t.mine ? Color.accentColor : Color(.systemGray5)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 1)
            .sheet(isPresented: $showReactionsPopup) {
                ReactionsPopupView(bookId: viewModel.book.id, messageId: message.id)
            }
        }
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
            ZStack(alignment: .bottomTrailing) {
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
                // #146 — text could never reach .sending/.failed visibly before (no retry
                // queue existed, so a failed send was just removed); now that it can, give it
                // the same overlay media bubbles already have.
                if message.sendState == .sending {
                    SendStateBadge(state: .sending).padding(4)
                } else if message.sendState == .failed {
                    SendStateBadge(
                        state: .failed,
                        onRetry: { Task { await viewModel.retryTextMessage(id: message.id) } },
                        onCancel: { viewModel.cancelTextMessage(id: message.id) }
                    ).padding(4)
                }
            }

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

// #47 — who reacted with what, loaded on demand when a reaction pill is tapped.
struct ReactionsPopupView: View {
    let bookId: UUID
    let messageId: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var reactors: [APIClient.ReactionReactor] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                } else if reactors.isEmpty {
                    Text("No reactions").foregroundColor(.secondary)
                } else {
                    List(reactors) { r in
                        HStack(spacing: 10) {
                            Text(r.emoji).font(.title3)
                            Text(r.displayName)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .task {
            reactors = (try? await APIClient.shared.reactionReactors(bookId: bookId, messageId: messageId)) ?? []
            loading = false
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
    // The "now playing" voice bubble. Was pure black, which vanished against the dark-mode
    // chat background (#56). A vivid, saturated blue reads clearly in both light and dark
    // mode, and the white chip / bar / text already contrast strongly against it.
    static let activePlaying = Color(red: 0.10, green: 0.45, blue: 0.95)
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
                // Defer focus past the initial layout pass. Forcing @FocusState in a
                // bare .onAppear raises the keyboard mid-layout which, with a resizing
                // detent, can thrash the keyboard in an infinite show/hide loop in
                // Release builds (#50).
                .task {
                    try? await Task.sleep(for: .milliseconds(50))
                    focused = true
                }
        }
        // .large (full height) instead of .medium: a medium sheet resizes when the
        // keyboard appears, which is what fed the keyboard loop above (#50).
        .presentationDetents([.large])
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
    @ObservedObject private var heard = HeardStore.shared
    @GestureState private var isScrubbing = false
    @State private var showSpeedSlider = false
    @State private var showTranscription = false
    @State private var transcription: String?
    @State private var isTranscribing = false

    private var isPlaying: Bool { audio.playingMessageId == message.id }
    private var isSending: Bool { message.sendState == .sending }
    private var isFailed: Bool { message.sendState == .failed }
    private var totalSeconds: Int { message.durationSeconds ?? 0 }
    // Fully listened: the play circle goes green once the audio has reached the end. For
    // others' messages that's the heard state — shared across your devices and sticky through
    // replays; for your own it's just this device's playback position, since "heard" isn't a
    // thing you can be about your own message.
    private var isFullyPlayed: Bool { heard.isHeard(message.id) || store.isCompleted(message.id) }
    // The "my message" blue — softer/muted vs the vivid system blue. Shared by the
    // bubble and the play icon so they read as one color family.
    private var myBlue: Color { .myMessageBlue }

    // All three play/pause controls share one circle "chip" of the same size: a light
    // chip with a dark/accent icon. White chip on own (blue) bubbles and while playing
    // (the active blue bubble); grey chip on others' (grey) bubbles.
    private var chipBackground: Color {
        if isPlaying { return .white }
        // Soft white (not pure white) on own bubbles so the chip doesn't irradiate
        // against the blue and read as oversized; the others' chip is darker than its
        // grey bubble by a comparable amount so both read as the same visual weight.
        return isMe ? .softWhite : Color(.systemGray2)
    }
    private var chipIconColor: Color {
        if isPlaying { return .black }
        // .primary (not the fixed UIColor.darkGray, which doesn't adapt) so the play glyph on
        // others' grey bubbles stays high-contrast in dark mode too — dark on the light-mode
        // chip, light on the dark-mode chip, instead of a dark-grey icon vanishing into it.
        return isMe ? myBlue : .primary
    }
    // Live position while playing; otherwise the persisted resume position.
    private var displayFraction: Double {
        if isPlaying { return audio.progress }
        guard totalSeconds > 0 else { return 0 }
        let position = store.position(for: message.id)
        // A finished message whose stored position is within a second of the end is at the end:
        // the gap is integer rounding between the media's real length and the recorded duration,
        // not audio left unheard. Without this, messages finished before the write was corrected
        // keep drawing a bar that stops just short.
        if store.isCompleted(message.id), position >= Double(totalSeconds) - 1 { return 1 }
        return min(position / Double(totalSeconds), 1)
    }
    // Progress bar / thumb color, matched to the play control: white while playing
    // (blue bubble) and on own (blue) bubbles, adaptive on others' (grey) bubbles.
    private var barColor: Color {
        if isPlaying { return .white }
        // .secondary (not the fixed UIColor.darkGray) so the track stays visible on others'
        // grey bubbles in dark mode instead of fading into them.
        return isMe ? .softWhite : .secondary
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
        .background(isPlaying ? Color.activePlaying : (isMe ? myBlue : Color(.systemGray5)))
        .foregroundColor(isPlaying || isMe ? .white : .primary)
        .cornerRadius(16)
        .frame(maxWidth: isPlaying || showTranscription ? .infinity : 180)
        .animation(.easeInOut(duration: 0.25), value: isPlaying)
        .animation(.easeInOut(duration: 0.2), value: showTranscription)
        .onChange(of: isPlaying) { if !$0 { showSpeedSlider = false } }   // close popover when playback ends
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
                    // Voice draws its own inline send-state UI rather than using
                    // SendStateBadge, so it needs to carry the same identifiers or its state is
                    // invisible to tests. It genuinely was: testSendVoiceMessage asserted on
                    // failedSendIndicator, which this bubble never renders under any state, so
                    // the test passed even while every send was being rejected.
                    .accessibilityIdentifier("sendingIndicator")
            } else if isFailed {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(isMe ? .white.opacity(0.85) : .orange)
                    .frame(width: 36, height: 36)
                    .accessibilityIdentifier("failedSendIndicator")
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
                // Gives the voice-send UITest something positive to assert on. It previously
                // could only check for the absence of a failure badge, which is what let a
                // completely broken dev voice send stay green.
                .accessibilityIdentifier("voicePlayButton")
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
                Button { showSpeedSlider.toggle() } label: {
                    BunnySpeedIcon(speed: audio.playbackRate)
                        .frame(width: 44, height: 44)
                }
                .popover(isPresented: $showSpeedSlider) {
                    VerticalSpeedSlider(rate: audio.playbackRate) { audio.setRate($0) }
                        .popoverCompactAdaptation()
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
        // Include the time so a weekday ("Tuesday") is actually referenceable — there
        // are many Tuesdays (#89/#63). e.g. "Tuesday 3:45 PM".
        return date.formatted(.dateTime.weekday(.wide).hour().minute())
    } else {
        // Older messages: full date + time so they can be pinpointed, e.g.
        // "Jul 3, 2026, 3:45 PM".
        return date.formatted(date: .abbreviated, time: .shortened)
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

    @ObservedObject private var aspects = ImageAspectStore.shared

    // The bubble takes the photo's own shape instead of a fixed square (#122). A square with
    // scaledToFill cropped every non-square photo — sides off a landscape, head and feet off a
    // portrait — so people had to open each one to see what it was.
    private static let maxWidth: CGFloat = 240
    private static let maxHeight: CGFloat = 300

    private var aspect: CGFloat { aspects.aspect(for: url) ?? ImageAspectStore.placeholder }

    // Fit the image's ratio inside the bounding box: wide photos meet the width limit, tall ones
    // meet the height limit, and neither is cropped.
    private var displaySize: CGSize {
        let byWidth = CGSize(width: Self.maxWidth, height: Self.maxWidth / aspect)
        return byWidth.height <= Self.maxHeight
            ? byWidth
            : CGSize(width: Self.maxHeight * aspect, height: Self.maxHeight)
    }

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
                    .frame(width: displaySize.width, height: displaySize.height)
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
            // A local file is a send in flight; measuring it here means the bubble is the right
            // shape from the first frame, and stays that shape when the server copy replaces it.
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .onAppear { aspects.record(image, for: url) }
        } else {
            CachedRemoteImage(url: url, onDecoded: { aspects.record($0, for: url) }) { phase in
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
                // Paired with failedSendIndicator so a test can assert the discrete send state
                // directly: a message is confirmed exactly when it carries neither badge
                // (sendState == nil after reconciliation). Asserting "no failure appeared" alone
                // can't tell a success apart from a send that is still in flight.
                .accessibilityIdentifier("sendingIndicator")
        case .failed:
            Menu {
                Button { onRetry?() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                Button(role: .destructive) { onCancel?() } label: { Label("Cancel", systemImage: "xmark") }
            } label: {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white, .red)
                    .accessibilityIdentifier("failedSendIndicator")
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

// Compact speed indicator for the bunny button: a hare plus the current multiplier, so a
// continuous rate (e.g. 2.25×) reads clearly. Tapping the button opens SpeedSliderPopup.
struct BunnySpeedIcon: View {
    let speed: Float

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: speed <= 1.0 ? "hare" : "hare.fill")
                .font(.system(size: 16, weight: speed >= 3.0 ? .bold : .regular))
            Text(Self.label(speed))
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
        }
    }

    // 1.0 → "1×", 2.0 → "2×", 2.25 → "2.25×" (trailing zeros dropped).
    static func label(_ speed: Float) -> String {
        let r = (speed * 100).rounded() / 100
        return r == r.rounded() ? "\(Int(r))×" : String(format: "%g×", r)
    }
}

// Vertical 1–4× speed slider shown in a popover anchored to the bunny (hare = faster on top,
// tortoise = slower at the bottom). Free-flowing (#61) — lands on any speed, with a light
// haptic detent only at whole multipliers. Applies the rate live (persisted via
// AudioPlayerService). Custom track for reliable vertical drag.
struct VerticalSpeedSlider: View {
    let rate: Float
    let onChange: (Float) -> Void

    @State private var value: Double
    @State private var lastDetent: Int
    private let haptic = UISelectionFeedbackGenerator()

    init(rate: Float, onChange: @escaping (Float) -> Void) {
        self.rate = rate
        self.onChange = onChange
        _value = State(initialValue: Double(rate))
        _lastDetent = State(initialValue: Int(Double(rate)))
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hare.fill").font(.system(size: 13))
            Text(BunnySpeedIcon.label(Float(value)))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            SpeedTrack(value: $value) { newValue in
                // Haptic only when crossing a whole multiplier, so a free-flowing drag
                // still gets a light tactile detent at 1×/2×/3×/4× without buzzing continuously.
                let detent = Int(newValue)
                if detent != lastDetent { haptic.selectionChanged(); lastDetent = detent }
                onChange(Float(newValue))
            }
            .frame(width: 40, height: 150)
            Image(systemName: "tortoise.fill").font(.system(size: 13))
        }
        .foregroundColor(.secondary)
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .onAppear { haptic.prepare() }
    }
}

// Vertical track for the speed slider. Split out (with explicit numeric types) because the
// mixed CGFloat/Double math in one large view body times out the Xcode 16.4 type-checker.
private struct SpeedTrack: View {
    @Binding var value: Double
    let onChange: (Double) -> Void   // fired when the (free-flowing) value changes

    var body: some View {
        GeometryReader { geo in
            let h: CGFloat = geo.size.height
            let frac: CGFloat = CGFloat((value - 1.0) / 3.0)   // 1–4× → 0–1
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.secondary.opacity(0.25)).frame(width: 6)
                Capsule().fill(Color.accentColor).frame(width: 6, height: h * frac)
                thumb.offset(y: -(h - 24) * frac)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(drag(height: h))
        }
    }

    private var thumb: some View {
        Circle().fill(Color(.systemBackground))
            .frame(width: 24, height: 24)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
    }

    private func drag(height h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { v in
            let f: Double = max(0, min(1, 1 - Double(v.location.y / h)))   // top = fast
            // Free-flowing (#61): land on any speed. Round to 0.05 only so the label
            // doesn't jitter to two decimals — no coarse 0.25× detents.
            let precise: Double = ((1.0 + f * 3.0) * 20).rounded() / 20
            if precise != value {
                value = precise
                onChange(precise)
            }
        }
    }
}

extension View {
    // Render a popover as a true anchored popover on iPhone too (iOS 16.4+); on older OSes
    // it falls back to the default sheet adaptation.
    @ViewBuilder func popoverCompactAdaptation() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationCompactAdaptation(.popover)
        } else {
            self
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
        NavigationStack {
            BookDetailView(book: Book(
                id: UUID(), clubId: UUID(),
                title: "Dune", author: "Frank Herbert",
                addedAt: Date(), finishedAt: nil, status: .future
            ))
        }
    }
}
