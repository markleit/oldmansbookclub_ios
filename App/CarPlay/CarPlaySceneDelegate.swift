import CarPlay
import UIKit

// CarPlay browse + play scene (issue #46). Separate scene in the same app process, so it
// reuses APIClient, AudioPlayerService, PlaybackProgressStore, etc. Phase-1 scope: browse
// books → recent voice messages, play, and auto-advance through unheard ("play all unheard").
// NOTE: requires the carplay-audio entitlement (pending Apple approval) to appear on a real
// CarPlay head unit; builds + the CarPlay Simulator work for development meanwhile.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let root = CPListTemplate(title: "Old Man's Book Club", sections: [])
        root.emptyViewTitleVariants = ["Books"]
        root.emptyViewSubtitleVariants = ["Loading…"]
        interfaceController.setRootTemplate(root, animated: false, completion: nil)
        Task { await loadBooks(into: root) }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }

    // MARK: - Books

    private func loadBooks(into template: CPListTemplate) async {
        let books = (try? await APIClient.shared.getMyBooks()) ?? []
        guard !books.isEmpty else {
            template.emptyViewSubtitleVariants = ["Sign in on your phone to see your books."]
            template.updateSections([])
            return
        }
        let items: [CPListItem] = books.map { book in
            let item = CPListItem(text: book.title,
                                  detailText: book.unreadCount > 0 ? "\(book.unreadCount) new" : nil)
            item.handler = { [weak self] _, completion in
                Task { await self?.openBook(book); completion() }
            }
            return item
        }
        template.updateSections([CPListSection(items: items)])
    }

    // MARK: - Messages

    private func openBook(_ book: Book) async {
        let messages = (try? await APIClient.shared.getMessages(bookId: book.id)) ?? []
        // Voice messages only, oldest→newest so "play all" runs in chat order.
        let voices = messages
            .filter { $0.type == .voice && !$0.isDeleted }
            .sorted { $0.sentAt < $1.sentAt }
        let unheard = voices.filter { !PlaybackProgressStore.shared.isCompleted($0.id) }

        var sections: [CPListSection] = []

        if !unheard.isEmpty {
            let playAll = CPListItem(text: "Play all unheard (\(unheard.count))", detailText: nil)
            playAll.handler = { [weak self] _, completion in
                self?.startQueue(unheard, from: unheard[0], bookId: book.id); completion()
            }
            sections.append(CPListSection(items: [playAll]))
        }

        let rows: [CPListItem] = voices.reversed().map { msg in   // newest first in the list
            let heard = PlaybackProgressStore.shared.isCompleted(msg.id)
            let title = TranscriptStore.shared.text(for: msg.id) ?? "🎤 Voice message"
            let item = CPListItem(text: (heard ? "" : "● ") + title,
                                  detailText: "\(msg.senderName) · \(Self.time(msg.sentAt))")
            item.handler = { [weak self] _, completion in
                self?.startQueue(voices, from: msg, bookId: book.id); completion()
            }
            // Warm the transcript so the row becomes readable on a later refresh.
            TranscriptStore.shared.transcribeIfNeeded(messageId: msg.id, mediaUrlString: msg.mediaUrl)
            return item
        }
        sections.append(CPListSection(items: rows))

        let template = CPListTemplate(title: book.title, sections: sections)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Playback

    // Play `start` and auto-advance through the rest of `queue` (chronological).
    private func startQueue(_ queue: [Message], from start: Message, bookId: UUID) {
        AudioPlayerService.shared.onPlaybackCompleted = { completedId in
            // Best-effort mark-heard so unread clears everywhere.
            Task { try? await APIClient.shared.markHeard(bookId: bookId, messageId: completedId) }
        }
        AudioPlayerService.shared.nextToPlay = { completedId in
            guard let idx = queue.firstIndex(where: { $0.id == completedId }), idx + 1 < queue.count else { return nil }
            return queue[idx + 1]
        }
        AudioPlayerService.shared.toggle(message: start)
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private static func time(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: date)
    }
}
