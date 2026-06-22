import CarPlay
import UIKit
import MediaPlayer
import Combine
import AVFoundation

// CarPlay browse + play scene (issue #46). Reuses the app's singletons (APIClient,
// AudioPlayerService, TranscriptStore, PlaybackProgressStore). Browse clubs → books →
// messages, and play continuously: selecting any message plays it then auto-advances —
// voice → audio, text → read aloud (TTS), photo/video skipped.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
                                  CPInterfaceControllerDelegate, AVSpeechSynthesizerDelegate {
    private var interfaceController: CPInterfaceController?
    private let synthesizer = AVSpeechSynthesizer()

    // Continuous playback queue (mixed types, chronological).
    private var playQueue: [Message] = []
    private var playIndex = 0
    private var currentBookId: UUID?
    private var remoteCommandsConfigured = false
    // Per-template refresh closures, run when a list reappears (e.g. after backing out of
    // playback) so unread counts / unheard dots reflect what was just played.
    private var refreshers: [ObjectIdentifier: () async -> Void] = [:]

    // MARK: - Scene lifecycle

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        interfaceController.delegate = self
        synthesizer.delegate = self
        let root = CPListTemplate(title: "Old Man's Book Club", sections: [])
        root.emptyViewTitleVariants = ["Loading…"]
        interfaceController.setRootTemplate(root, animated: false, completion: nil)
        Task { await loadClubs(into: root) }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }

    // Back out of Now Playing → stop playback.
    nonisolated func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        Task { @MainActor in
            if aTemplate === CPNowPlayingTemplate.shared { self.stopPlayback() }
        }
    }

    // A list reappeared (e.g. backed out of playback) → refresh its counts.
    nonisolated func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
        Task { @MainActor in
            await self.refreshers[ObjectIdentifier(aTemplate)]?()
        }
    }

    // MARK: - Clubs → Books

    private func loadClubs(into template: CPListTemplate) async {
        let clubs = (try? await APIClient.shared.getMyClubs()) ?? []
        let books = (try? await APIClient.shared.getMyBooks()) ?? []
        guard !clubs.isEmpty else {
            template.emptyViewSubtitleVariants = ["Sign in on your phone to see your clubs."]
            template.updateSections([]); return
        }
        // Single club → skip the chooser, go straight to its books (refresh on reappear).
        if clubs.count == 1 {
            let cid = clubs[0].id
            template.updateSections(bookSections(books.filter { $0.clubId == cid }))
            refreshers[ObjectIdentifier(template)] = { [weak self, weak template] in
                guard let self, let template else { return }
                let fresh = (try? await APIClient.shared.getMyBooks()) ?? []
                template.updateSections(self.bookSections(fresh.filter { $0.clubId == cid }))
            }
            return
        }
        let items = clubs.map { club -> CPListItem in
            let count = books.filter { $0.clubId == club.id }.reduce(0) { $0 + $1.unreadCount }
            let item = CPListItem(text: club.name, detailText: count > 0 ? "\(count) new" : nil)
            item.handler = { [weak self] _, completion in
                guard let self else { completion(); return }
                let cid = club.id
                let t = CPListTemplate(title: club.name, sections: self.bookSections(books.filter { $0.clubId == cid }))
                self.refreshers[ObjectIdentifier(t)] = { [weak self, weak t] in
                    guard let self, let t else { return }
                    let fresh = (try? await APIClient.shared.getMyBooks()) ?? []
                    t.updateSections(self.bookSections(fresh.filter { $0.clubId == cid }))
                }
                self.interfaceController?.pushTemplate(t, animated: true, completion: nil)
                completion()
            }
            return item
        }
        template.updateSections([CPListSection(items: items)])
    }

    private func bookSections(_ books: [Book]) -> [CPListSection] {
        let items = books.map { book -> CPListItem in
            let item = CPListItem(text: book.title, detailText: book.unreadCount > 0 ? "\(book.unreadCount) new" : nil)
            item.handler = { [weak self] _, completion in
                Task { await self?.openBook(book); completion() }
            }
            return item
        }
        return [CPListSection(items: items)]
    }

    // MARK: - Messages

    private func openBook(_ book: Book) async {
        let template = CPListTemplate(title: book.title, sections: [])
        template.emptyViewTitleVariants = ["Loading…"]
        let refresh: () async -> Void = { [weak self, weak template] in
            guard let self, let template else { return }
            let messages = (try? await APIClient.shared.getMessages(bookId: book.id)) ?? []
            template.updateSections(self.messageSections(book: book, messages: messages))
        }
        refreshers[ObjectIdentifier(template)] = refresh
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
        await refresh()   // initial populate; templateWillAppear refreshes on re-entry
    }

    private func messageSections(book: Book, messages: [Message]) -> [CPListSection] {
        for m in messages where m.transcript != nil { TranscriptStore.shared.cache(m.transcript!, for: m.id) }
        let active = messages.filter { !$0.isDeleted }.sorted { $0.sentAt < $1.sentAt }   // chronological

        var sections: [CPListSection] = []
        // "Play all unheard" — start continuous playback from the oldest unheard voice.
        let unheard = active.filter { $0.type == .voice && !PlaybackProgressStore.shared.isCompleted($0.id) }
        if let first = unheard.first {
            let playAll = CPListItem(text: "Play all unheard (\(unheard.count))", detailText: nil)
            playAll.handler = { [weak self] _, completion in
                self?.playFrom(first.id, messages: active, bookId: book.id); completion()
            }
            sections.append(CPListSection(items: [playAll]))
        }

        // All message types, newest first. Voice/text start continuous playback from that
        // point; photo/video are non-actionable (and skipped during playback).
        let rows: [CPListItem] = active.reversed().map { msg in
            let sub = "\(msg.senderName) · \(Self.time(msg.sentAt))"
            let item: CPListItem
            switch msg.type {
            case .voice:
                let heard = PlaybackProgressStore.shared.isCompleted(msg.id)
                item = CPListItem(text: (heard ? "" : "● ") + (TranscriptStore.shared.text(for: msg.id) ?? "🎤 Voice message"), detailText: sub)
                TranscriptStore.shared.transcribeIfNeeded(messageId: msg.id, mediaUrlString: msg.mediaUrl)
                item.handler = { [weak self] _, completion in
                    self?.playFrom(msg.id, messages: active, bookId: book.id); completion()
                }
            case .text:
                item = CPListItem(text: msg.body ?? "", detailText: sub)
                item.handler = { [weak self] _, completion in
                    self?.playFrom(msg.id, messages: active, bookId: book.id); completion()
                }
            case .photo:
                item = CPListItem(text: "📷 Photo", detailText: sub)
                item.handler = { _, completion in completion() }
            case .video:
                item = CPListItem(text: "🎬 Video", detailText: sub)
                item.handler = { _, completion in completion() }
            case .unknown:
                item = CPListItem(text: "Message", detailText: sub)
                item.handler = { _, completion in completion() }
            }
            return item
        }
        sections.append(CPListSection(items: rows))
        return sections
    }

    // MARK: - Continuous playback (voice audio + text TTS, skipping photo/video)

    private func playFrom(_ messageId: UUID, messages: [Message], bookId: UUID) {
        playQueue = messages
        playIndex = messages.firstIndex(where: { $0.id == messageId }) ?? 0
        currentBookId = bookId
        configureRemoteCommands()
        // We drive advancement ourselves (mixed types); use AudioPlayerService's completion
        // only as the "voice finished" signal, not its own auto-advance.
        AudioPlayerService.shared.nextToPlay = nil
        AudioPlayerService.shared.onPlaybackCompleted = { [weak self] completedId in
            if let bid = self?.currentBookId {
                Task { try? await APIClient.shared.markHeard(bookId: bid, messageId: completedId) }
            }
            self?.advance()
        }
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        playCurrent()
    }

    private func playCurrent() {
        guard playQueue.indices.contains(playIndex) else {
            // Reached the end — leave the last message on the Now Playing screen (don't
            // blank it), just stop playback.
            AudioPlayerService.shared.stopAll(deactivateSession: false)
            synthesizer.stopSpeaking(at: .immediate)
            if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
            return
        }
        let msg = playQueue[playIndex]
        switch msg.type {
        case .voice:
            updateNowPlaying(title: TranscriptStore.shared.text(for: msg.id) ?? "Voice message",
                             artist: msg.senderName, duration: Double(msg.durationSeconds ?? 0))
            AudioPlayerService.shared.toggle(message: msg)            // completion → advance
        case .text:
            let body = msg.body ?? ""
            updateNowPlaying(title: body, artist: msg.senderName, duration: 0)
            AudioPlayerService.shared.stopAll(deactivateSession: false)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
            try? AVAudioSession.sharedInstance().setActive(true)
            synthesizer.stopSpeaking(at: .immediate)
            synthesizer.speak(AVSpeechUtterance(string: "\(msg.senderName) says: \(body)"))   // didFinish → advance
        default:
            advance()   // skip photo/video/unknown
        }
    }

    private func advance() {
        playIndex += 1
        playCurrent()
    }

    private func stopPlayback() {
        AudioPlayerService.shared.stopAll()
        synthesizer.stopSpeaking(at: .immediate)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.advance() }
    }

    // MARK: - Now Playing + transport controls

    private func updateNowPlaying(title: String, artist: String, duration: Double) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(AudioPlayerService.shared.currentSeconds)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.skip(1) ?? .commandFailed }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.skip(-1) ?? .commandFailed }
    }

    private func resume() {
        guard playQueue.indices.contains(playIndex) else { return }
        let msg = playQueue[playIndex]
        if msg.type == .text {
            if synthesizer.isPaused { synthesizer.continueSpeaking() } else { playCurrent() }
        } else if msg.type == .voice {
            AudioPlayerService.shared.toggle(message: msg)
        }
    }

    private func pause() {
        AudioPlayerService.shared.pause()
        if synthesizer.isSpeaking { synthesizer.pauseSpeaking(at: .word) }
    }

    // Skip to the next playable (voice/text) in the given direction, hopping over photo/video.
    private func skip(_ offset: Int) -> MPRemoteCommandHandlerStatus {
        var target = playIndex + offset
        while playQueue.indices.contains(target),
              ![MessageType.voice, .text].contains(playQueue[target].type) {
            target += offset
        }
        guard playQueue.indices.contains(target) else { return .noSuchContent }
        AudioPlayerService.shared.stopAll(deactivateSession: false)
        synthesizer.stopSpeaking(at: .immediate)
        playIndex = target
        playCurrent()
        return .success
    }

    // Matches the phone's formatMessageDate: time today, weekday this week, date older.
    private static func time(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        } else {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
    }
}
