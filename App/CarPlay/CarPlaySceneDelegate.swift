import CarPlay
import UIKit
import MediaPlayer
import Combine
import AVFoundation

// CarPlay browse + play scene (issue #46). Separate scene in the same app process, so it
// reuses APIClient, AudioPlayerService, PlaybackProgressStore, etc. Browse books → recent
// voice messages, play, auto-advance through unheard, with Now Playing metadata + transport
// controls (play/pause/next/prev) and stop-on-back.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPInterfaceControllerDelegate {
    private var interfaceController: CPInterfaceController?
    private var currentQueue: [Message] = []
    private var currentBookId: UUID?
    private var lastPlayedId: UUID?
    private var playingCancellable: AnyCancellable?
    private var remoteCommandsConfigured = false
    private let synthesizer = AVSpeechSynthesizer()

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        interfaceController.delegate = self
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

    // Back out of Now Playing → stop playback (and clear the Now Playing info).
    nonisolated func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        Task { @MainActor in
            if aTemplate === CPNowPlayingTemplate.shared {
                AudioPlayerService.shared.stopAll()
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
        }
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
        // Seed transcripts the server already has so rows read them immediately.
        for m in messages where m.transcript != nil {
            TranscriptStore.shared.cache(m.transcript!, for: m.id)
        }
        let active = messages.filter { !$0.isDeleted }.sorted { $0.sentAt > $1.sentAt }   // newest first
        let voices = messages.filter { $0.type == .voice && !$0.isDeleted }.sorted { $0.sentAt < $1.sentAt }
        let unheard = voices.filter { !PlaybackProgressStore.shared.isCompleted($0.id) }

        var sections: [CPListSection] = []
        if !unheard.isEmpty {
            let playAll = CPListItem(text: "Play all unheard voice (\(unheard.count))", detailText: nil)
            playAll.handler = { [weak self] _, completion in
                self?.startQueue(unheard, from: unheard[0], bookId: book.id); completion()
            }
            sections.append(CPListSection(items: [playAll]))
        }

        // All message types as rows. Voice plays; text is read aloud (TTS); photo/video
        // are non-actionable line items.
        let rows: [CPListItem] = active.map { msg in
            let sub = "\(msg.senderName) · \(Self.time(msg.sentAt))"
            switch msg.type {
            case .voice:
                let heard = PlaybackProgressStore.shared.isCompleted(msg.id)
                let title = TranscriptStore.shared.text(for: msg.id) ?? "🎤 Voice message"
                let item = CPListItem(text: (heard ? "" : "● ") + title, detailText: sub)
                item.handler = { [weak self] _, completion in
                    self?.startQueue(voices, from: msg, bookId: book.id); completion()
                }
                TranscriptStore.shared.transcribeIfNeeded(messageId: msg.id, mediaUrlString: msg.mediaUrl)
                return item
            case .text:
                let item = CPListItem(text: msg.body ?? "", detailText: sub)
                item.handler = { [weak self] _, completion in
                    self?.speak(msg.body ?? "", sender: msg.senderName); completion()
                }
                return item
            case .photo:
                let item = CPListItem(text: "📷 Photo", detailText: sub)
                item.handler = { _, completion in completion() }   // non-actionable
                return item
            case .video:
                let item = CPListItem(text: "🎬 Video", detailText: sub)
                item.handler = { _, completion in completion() }   // non-actionable
                return item
            case .unknown:
                let item = CPListItem(text: "Message", detailText: sub)
                item.handler = { _, completion in completion() }
                return item
            }
        }
        sections.append(CPListSection(items: rows))

        let template = CPListTemplate(title: book.title, sections: sections)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // Read a text message aloud through the car (iMessage-style). Stops any audio first.
    private func speak(_ text: String, sender: String) {
        guard !text.isEmpty else { return }
        AudioPlayerService.shared.stopAll(deactivateSession: false)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(AVSpeechUtterance(string: "\(sender) says: \(text)"))
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: text,
            MPMediaItemPropertyArtist: sender
        ]
    }

    // MARK: - Playback

    // Play `start` and auto-advance through the rest of `queue` (chronological).
    private func startQueue(_ queue: [Message], from start: Message, bookId: UUID) {
        currentQueue = queue
        currentBookId = bookId
        AudioPlayerService.shared.onPlaybackCompleted = { completedId in
            Task { try? await APIClient.shared.markHeard(bookId: bookId, messageId: completedId) }
        }
        AudioPlayerService.shared.nextToPlay = { [weak self] completedId in
            guard let q = self?.currentQueue,
                  let idx = q.firstIndex(where: { $0.id == completedId }), idx + 1 < q.count else { return nil }
            return q[idx + 1]
        }
        configureRemoteCommands()
        // Keep the Now Playing screen + lock-screen info in sync as playback advances.
        playingCancellable = AudioPlayerService.shared.$playingMessageId
            .sink { [weak self] id in self?.updateNowPlaying(for: id) }
        AudioPlayerService.shared.toggle(message: start)
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func updateNowPlaying(for id: UUID?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let id, let msg = currentQueue.first(where: { $0.id == id }) else { return }
        lastPlayedId = id
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = TranscriptStore.shared.text(for: id) ?? "Voice message"
        info[MPMediaItemPropertyArtist] = msg.senderName
        info[MPMediaItemPropertyPlaybackDuration] = Double(msg.durationSeconds ?? 0)
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(AudioPlayerService.shared.currentSeconds)
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        center.nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            guard let id = self?.lastPlayedId,
                  let msg = self?.currentQueue.first(where: { $0.id == id }) else { return .commandFailed }
            AudioPlayerService.shared.toggle(message: msg)   // resume from saved position
            return .success
        }
        c.pauseCommand.addTarget { _ in
            AudioPlayerService.shared.pause()
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.skip(by: 1) ?? .commandFailed }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.skip(by: -1) ?? .commandFailed }
    }

    private func skip(by offset: Int) -> MPRemoteCommandHandlerStatus {
        guard let id = AudioPlayerService.shared.playingMessageId ?? lastPlayedId,
              let idx = currentQueue.firstIndex(where: { $0.id == id }) else { return .commandFailed }
        let target = idx + offset
        guard currentQueue.indices.contains(target) else { return .noSuchContent }
        AudioPlayerService.shared.toggle(message: currentQueue[target])
        return .success
    }

    private static func time(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; return f.string(from: date)
    }
}
