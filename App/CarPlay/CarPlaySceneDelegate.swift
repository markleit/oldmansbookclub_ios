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
                                  CPInterfaceControllerDelegate, AVSpeechSynthesizerDelegate,
                                  AVAudioPlayerDelegate {
    private var interfaceController: CPInterfaceController?
    // The CarPlay scene, kept to read its activationState (#60): distinguishes a genuine in-app
    // back-press out of Now Playing (scene still foregroundActive → stop) from the app being
    // backgrounded by Maps / the CarPlay home / another audio app (→ keep playing).
    private weak var templateScene: CPTemplateApplicationScene?
    private let synthesizer = AVSpeechSynthesizer()
    // Offline TTS rendering only (AVSpeechSynthesizer.write → file). The LIVE synthesizer engine
    // speaking over the wireless CarPlay route reconfigures the shared audio path and wedges it
    // system-wide (our voice playback AND other apps like Spotify skip afterwards, persistently).
    // Rendering to a file keeps the engine off the route; we then play the file like any voice clip.
    private let renderSynth = AVSpeechSynthesizer()
    private var ttsPlayer: AVAudioPlayer?
    // Identifies the in-flight render so a newer text/skip can supersede a stale one.
    private var ttsRenderToken = UUID()

    // Now Playing album art (#55) — the app icon, built once and reused for every track.
    // Return an image rendered at the requested bounds (some Now Playing renderers won't draw
    // artwork whose returned size doesn't match the size they asked for).
    private static let nowPlayingArtwork: MPMediaItemArtwork? = {
        guard let img = UIImage(named: "AppLogo") else { return nil }
        return MPMediaItemArtwork(boundsSize: img.size) { size in
            UIGraphicsImageRenderer(size: size).image { _ in
                img.draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }()

    // Our authoritative copy of the Now Playing info. We mutate this and always write the WHOLE
    // dict — never read it back from MPNowPlayingInfoCenter, whose getter does not reliably return
    // the artwork we set, so a read-modify-write would silently drop the album art (it showed at
    // each message start via updateNowPlaying, then vanished on the next elapsed update). Keeping
    // the art in npInfo means every commit re-asserts it.
    private var npInfo: [String: Any] = [:]

    // Continuous playback queue (mixed types, chronological).
    private var playQueue: [Message] = []
    private var playIndex = 0
    private var currentBookId: UUID?
    private var remoteCommandsConfigured = false
    // True while reading a text message aloud (TTS). During TTS the audio player is idle, so
    // the playback observer must not interpret that as "paused" and zero the Now Playing rate.
    private var isSpeakingTTS = false
    // The utterance we're currently reading. didFinish/stopSpeaking can fire for a superseded
    // utterance (e.g. when skipping), so we only auto-advance when the finished utterance is
    // still the current one — otherwise a stale callback yanks playIndex forward.
    private var currentUtterance: AVSpeechUtterance?
    // Per-template refresh closures, run when a list reappears (e.g. after backing out of
    // playback) so unread counts / unheard dots reflect what was just played.
    private var refreshers: [ObjectIdentifier: () async -> Void] = [:]
    // Re-render the open message list as on-device transcriptions land (so voice rows fill
    // in their transcripts consistently instead of some showing and some not).
    private var transcriptObserver: AnyCancellable?
    // The phone's AudioPlayerService doesn't publish play/pause state to the system Now
    // Playing center, so CarPlay's transport can fall out of sync when you start/stop on the
    // phone (showing paused while audio plays → needing a double-press). Observe the shared
    // player and keep the Now Playing rate (and title) in sync from the CarPlay side.
    private var playbackObserver: AnyCancellable?
    // Drives the Now Playing elapsed time from the player's real position each second so the
    // CarPlay progress bar actually shows and tracks (extrapolation alone often won't render).
    private var progressObserver: AnyCancellable?
    // While the item clock isn't advancing (route warming on CarPlay, 1–2s), report rate 0 to Now
    // Playing so the system doesn't extrapolate the scrubber forward and then snap it back to 0
    // when real audio starts (the visible "timer restart"). Flip to rate 1 once it's advancing.
    private var advancingObserver: AnyCancellable?
    // Observe sign-in/sign-out on the phone (#59). If the user signs in/out while CarPlay is
    // connected — e.g. sitting on the "Not signed in" root — pop back to root and reload so the
    // list reflects the new auth state without needing to navigate within CarPlay first.
    private var authObserver: AnyCancellable?
    // The root clubs/books template, kept so an auth change can pop back to it and reload.
    private weak var rootTemplate: CPListTemplate?

    // MARK: - Scene lifecycle

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        self.templateScene = scene
        interfaceController.delegate = self
        synthesizer.delegate = self
        let root = CPListTemplate(title: "Old Man's Book Club", sections: [])
        root.emptyViewTitleVariants = ["Loading…"]
        rootTemplate = root
        interfaceController.setRootTemplate(root, animated: false, completion: nil)
        authObserver = NotificationCenter.default.publisher(for: .authStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleAuthStateChange() }
        playbackObserver = AudioPlayerService.shared.$playingMessageId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.syncNowPlayingState(playingId: id) }
        progressObserver = AudioPlayerService.shared.$currentSeconds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] secs in
                guard let self, !self.isSpeakingTTS,
                      AudioPlayerService.shared.playingMessageId != nil, !self.npInfo.isEmpty else { return }
                self.npInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(secs)
                self.npInfo[MPNowPlayingInfoPropertyPlaybackRate] = AudioPlayerService.shared.isAdvancing ? 1.0 : 0.0
                self.commitNowPlaying()
            }
        advancingObserver = AudioPlayerService.shared.$isAdvancing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] advancing in
                guard let self, !self.isSpeakingTTS,
                      AudioPlayerService.shared.playingMessageId != nil, !self.npInfo.isEmpty else { return }
                // Pin elapsed to the real position and only run the clock (rate 1) once the item
                // clock is ACTUALLY advancing. timeControlStatus == .playing fires during the
                // route warmup (automaticallyWaitsToMinimizeStalling = false) while the clock is
                // still 0, which let the scrubber extrapolate ahead and then snap back.
                self.npInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(AudioPlayerService.shared.currentSeconds)
                self.npInfo[MPNowPlayingInfoPropertyPlaybackRate] = advancing ? 1.0 : 0.0
                self.commitNowPlaying()
            }
        // Adopt playback already in progress (e.g. started on the phone before CarPlay
        // connected, or while its window was closed) — the observer only sees changes.
        if AudioPlayerService.shared.playingMessageId != nil {
            syncNowPlayingState(playingId: AudioPlayerService.shared.playingMessageId)
        }
        Task { await loadClubs(into: root) }
    }

    // Mirror the shared player's state into the CarPlay Now Playing screen, and — when the
    // phone starts a message we're not already showing — jump to and follow it (loading its
    // book if it's a different chat). Phone audio is always a voice message (text is never
    // audio), so adoption only ever deals with voice clips.
    private func syncNowPlayingState(playingId: UUID?) {
        guard let id = playingId else {
            // Player went idle. If we're reading text aloud (TTS), the player is legitimately
            // empty — don't stomp the "playing" state. Otherwise mark Now Playing paused.
            if isSpeakingTTS { return }
            if !npInfo.isEmpty {
                npInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
                commitNowPlaying()
            }
            return
        }
        // Already pointed at this message (CarPlay-initiated or already adopted) → keep fresh.
        if playQueue.indices.contains(playIndex), playQueue[playIndex].id == id { bumpNowPlayingRate(); return }
        // Same book, phone advanced to another loaded message → follow it.
        if let idx = playQueue.firstIndex(where: { $0.id == id }) { playIndex = idx; reflectAdopted(); return }
        // Different chat — adopt that book's queue so CarPlay jumps to and follows it.
        guard let bookId = AudioPlayerService.shared.playingBookId else { bumpNowPlayingRate(); return }
        Task { await adoptExternalPlayback(messageId: id, bookId: bookId) }
    }

    private func bumpNowPlayingRate() {
        guard !npInfo.isEmpty else { return }
        npInfo[MPNowPlayingInfoPropertyPlaybackRate] = AudioPlayerService.shared.isAdvancing ? 1.0 : 0.0
        npInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(AudioPlayerService.shared.currentSeconds)
        commitNowPlaying()
    }

    // Always write the WHOLE locally-owned dict (which retains the artwork). Never read back from
    // MPNowPlayingInfoCenter — see npInfo.
    private func commitNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = npInfo
    }

    // Show the now-current queue entry (started elsewhere) on CarPlay's Now Playing screen
    // without restarting it, and surface that screen if it isn't already up.
    private func reflectAdopted() {
        guard playQueue.indices.contains(playIndex) else { return }
        let msg = playQueue[playIndex]
        updateNowPlaying(title: TranscriptStore.shared.text(for: msg.id) ?? "Voice message",
                         artist: msg.senderName, duration: Double(msg.durationSeconds ?? 0))
        updateSkipButtons(voice: true)
        configureRemoteCommands()
        presentNowPlaying()
    }

    // Surface the shared Now Playing template. It's a singleton, so pushing it when it's
    // already in the nav stack fails ("already in hierarchy") — pop back to it instead.
    private func presentNowPlaying() {
        guard let ic = interfaceController else { return }
        if ic.topTemplate === CPNowPlayingTemplate.shared { return }
        if ic.templates.contains(where: { $0 === CPNowPlayingTemplate.shared }) {
            ic.pop(to: CPNowPlayingTemplate.shared, animated: true, completion: nil)
        } else {
            ic.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
    }

    // Load the book a phone-started message lives in, adopt it as our queue, and take over the
    // completion→advance driver so the CarPlay queue keeps moving from here.
    private func adoptExternalPlayback(messageId: UUID, bookId: UUID) async {
        let messages = (try? await APIClient.shared.getMessages(bookId: bookId)) ?? []
        for m in messages where m.transcript != nil { TranscriptStore.shared.cache(m.transcript!, for: m.id) }
        let active = messages.filter { !$0.isDeleted }.sorted { $0.sentAt < $1.sentAt }
        guard let idx = active.firstIndex(where: { $0.id == messageId }) else { return }
        playQueue = active
        playIndex = idx
        currentBookId = bookId
        AudioPlayerService.shared.nextToPlay = nil
        AudioPlayerService.shared.onPlaybackCompleted = { [weak self] completedId in
            if let bid = self?.currentBookId {
                Task { try? await APIClient.shared.markHeard(bookId: bid, messageId: completedId) }
            }
            self?.advance()
        }
        reflectAdopted()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        playbackObserver = nil
        progressObserver = nil
        advancingObserver = nil
        authObserver = nil
    }

    // Sign-in/sign-out happened on the phone while CarPlay is connected (#59). Signing out
    // invalidates the queue, so stop playback; then pop back to the root and reload it so the
    // list shows the right state (clubs when signed in, the sign-in prompt when signed out).
    private func handleAuthStateChange() {
        if TokenStore.shared.token == nil { stopPlayback() }
        guard let ic = interfaceController, let root = rootTemplate else { return }
        if ic.topTemplate !== root {
            ic.pop(to: root, animated: true, completion: nil)
        }
        Task { await loadClubs(into: root) }
    }

    // Now Playing disappeared. This fires for TWO cases we must distinguish (#60):
    //  • the user tapped BACK out of Now Playing (navigating within our app) → stop playback;
    //  • the app got BACKGROUNDED (Maps / CarPlay home / another audio app covered our scene)
    //    → a CarPlay audio app must KEEP playing, like Spotify/Podcasts.
    // The scene is still .foregroundActive only in the first case; when backgrounded it's
    // .foregroundInactive/.background. So stop only while foreground-active.
    nonisolated func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        Task { @MainActor in
            guard aTemplate === CPNowPlayingTemplate.shared else { return }
            if self.templateScene?.activationState == .foregroundActive { self.stopPlayback() }
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
        // Re-run on reappear so signing in/out on the phone is reflected (e.g. signed out →
        // shows the sign-in message; signed back in → shows clubs).
        refreshers[ObjectIdentifier(template)] = { [weak self, weak template] in
            guard let self, let template else { return }
            await self.loadClubs(into: template)
        }
        // Instant-paint the root from the phone's cached books (#101) before the network returns,
        // for the common single-club case (which skips the club chooser and shows books directly).
        // Only on the first paint (template still empty) so a reappear-refresh doesn't flicker;
        // multi-club needs club names we don't cache, so it waits for the network below. The
        // network fetch + seed() reconcile everything to server truth a moment later.
        if template.sections.isEmpty {
            let cachedBooks = LibraryViewModel.cachedBooks()
            if !cachedBooks.isEmpty, Set(cachedBooks.map { $0.clubId }).count == 1 {
                UnreadStore.shared.seed(from: cachedBooks)
                template.updateSections(bookSections(cachedBooks))
            }
        }
        // Fetch clubs and books concurrently (#101): they're independent, so awaiting them in
        // series made the root list wait on two full round-trips before painting.
        async let clubsReq = APIClient.shared.getMyClubs()
        async let booksReq = APIClient.shared.getMyBooks()
        let clubs = (try? await clubsReq) ?? []
        let books = (try? await booksReq) ?? []
        // Feed the shared UnreadStore so CarPlay and the phone read the SAME counts (#53). The
        // phone displays UnreadStore.counts (which it also mutates locally as you read/hear
        // messages); CarPlay previously showed raw book.unreadCount from its own fetch, so the
        // two drifted. Seeding here + reading via unreadCount(for:) keeps them identical.
        if !books.isEmpty { UnreadStore.shared.seed(from: books) }
        guard !clubs.isEmpty else {
            // Set BOTH title + subtitle (otherwise the title stays "Loading…" → looks blank /
            // stuck). Distinguish genuinely signed-out from signed-in-but-no-clubs.
            if TokenStore.shared.token == nil {
                template.emptyViewTitleVariants = ["Not signed in"]
                template.emptyViewSubtitleVariants = ["Open the Old Man's Book Club app on your phone and sign in."]
            } else {
                template.emptyViewTitleVariants = ["No clubs yet"]
                template.emptyViewSubtitleVariants = ["Join or create a club in the app on your phone."]
            }
            template.updateSections([]); return
        }
        // Single club → skip the chooser, go straight to its books (refresh on reappear).
        if clubs.count == 1 {
            let cid = clubs[0].id
            template.updateSections(bookSections(books.filter { $0.clubId == cid }))
            refreshers[ObjectIdentifier(template)] = { [weak self, weak template] in
                guard let self, let template else { return }
                let fresh = (try? await APIClient.shared.getMyBooks()) ?? []
                if !fresh.isEmpty { UnreadStore.shared.seed(from: fresh) }
                template.updateSections(self.bookSections(fresh.filter { $0.clubId == cid }))
            }
            return
        }
        let items = clubs.map { club -> CPListItem in
            let count = books.filter { $0.clubId == club.id }.reduce(0) { $0 + self.unreadCount(for: $1) }
            let item = CPListItem(text: club.name, detailText: count > 0 ? "\(count) new" : nil)
            item.handler = { [weak self] _, completion in
                guard let self else { completion(); return }
                let cid = club.id
                let t = CPListTemplate(title: club.name, sections: self.bookSections(books.filter { $0.clubId == cid }))
                self.refreshers[ObjectIdentifier(t)] = { [weak self, weak t] in
                    guard let self, let t else { return }
                    let fresh = (try? await APIClient.shared.getMyBooks()) ?? []
                    if !fresh.isEmpty { UnreadStore.shared.seed(from: fresh) }
                    t.updateSections(self.bookSections(fresh.filter { $0.clubId == cid }))
                }
                self.interfaceController?.pushTemplate(t, animated: true, completion: nil)
                completion()
            }
            return item
        }
        template.updateSections([CPListSection(items: items)])
    }

    // Leading icon for book rows — a consistent book glyph so the list reads as a bookshelf.
    // Template (not a baked color) so CarPlay tints it for the current appearance — a fixed
    // .label color resolves once at creation (light = black) and stays invisible in dark mode.
    private static let bookRowIcon: UIImage? = UIImage(
        systemName: "book.closed.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 36, weight: .regular))?
        .withRenderingMode(.alwaysTemplate)

    // Unread count for a book, read from the shared UnreadStore so it matches the phone exactly
    // (#53); falls back to the book's own server value if the store hasn't been seeded yet.
    private func unreadCount(for book: Book) -> Int {
        UnreadStore.shared.counts[book.id] ?? book.unreadCount
    }

    private func bookSections(_ books: [Book]) -> [CPListSection] {
        let items = books.map { book -> CPListItem in
            let count = unreadCount(for: book)
            let item = CPListItem(text: book.title,
                                  detailText: count > 0 ? "\(count) new" : nil,
                                  image: Self.bookRowIcon)
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
        // Re-render this list (debounced) as transcriptions complete so transcripts fill in.
        transcriptObserver = TranscriptStore.shared.$transcripts
            .dropFirst()
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { _ in Task { await refresh() } }
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
        // Instant paint from the phone's on-disk message cache (#101) so the list shows
        // immediately instead of a "Loading…" spinner while the network round-trips. refresh()
        // then reconciles to server truth. Falls back to "Loading…" if nothing's cached yet.
        let cached = ChatCache.load(bookId: book.id)
        if !cached.isEmpty { template.updateSections(messageSections(book: book, messages: cached)) }
        await refresh()   // initial populate; templateWillAppear refreshes on re-entry
    }

    private func messageSections(book: Book, messages: [Message]) -> [CPListSection] {
        for m in messages where m.transcript != nil { TranscriptStore.shared.cache(m.transcript!, for: m.id) }
        let active = messages.filter { !$0.isDeleted }.sorted { $0.sentAt < $1.sentAt }   // chronological
        let me = TokenStore.shared.userId

        var sections: [CPListSection] = []
        // "Play all unheard" — start continuous playback from the oldest unheard voice. Match
        // the phone's count: voice messages that aren't yours and aren't locally heard yet.
        let unheard = active.filter { $0.type == .voice && $0.senderId != me && !PlaybackProgressStore.shared.isCompleted($0.id) }
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
                // Always a 🎤 mic icon (consistent), then the transcript if we have one. Your
                // own messages never show the unheard dot (matches the phone).
                let heard = msg.senderId == me || PlaybackProgressStore.shared.isCompleted(msg.id)
                let body = TranscriptStore.shared.text(for: msg.id) ?? "Voice message"
                item = CPListItem(text: (heard ? "" : "● ") + "🎤 " + body, detailText: sub)
                // TEMP (skip investigation): eager on-device transcription of every row is a
                // CPU/IO burst that starves audio playback on battery → skips. Disabled to
                // confirm; if this fixes it, re-add deferred/serial transcription that pauses
                // while audio is playing.
                // TranscriptStore.shared.transcribeIfNeeded(messageId: msg.id, mediaUrlString: msg.mediaUrl)
                item.handler = { [weak self] _, completion in
                    self?.playFrom(msg.id, messages: active, bookId: book.id); completion()
                }
            case .text:
                // 💬 icon disambiguates a text message from a voice transcript.
                item = CPListItem(text: "💬 " + (msg.body ?? ""), detailText: sub)
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
        presentNowPlaying()
        playCurrent()
    }

    private func playCurrent() {
        guard playQueue.indices.contains(playIndex) else {
            // Reached the end — leave the last message on the Now Playing screen (don't
            // blank it), just stop playback.
            isSpeakingTTS = false
            currentUtterance = nil
            ttsRenderToken = UUID()
            ttsPlayer?.stop(); ttsPlayer = nil
            AudioPlayerService.shared.stopAll(deactivateSession: false)
            synthesizer.stopSpeaking(at: .immediate)
            if !npInfo.isEmpty {
                npInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
                commitNowPlaying()
            }
            return
        }
        let msg = playQueue[playIndex]
        switch msg.type {
        case .voice:
            isSpeakingTTS = false
            currentUtterance = nil
            updateNowPlaying(title: TranscriptStore.shared.text(for: msg.id) ?? "Voice message",
                             artist: msg.senderName, duration: Double(msg.durationSeconds ?? 0))
            updateSkipButtons(voice: true)           // ±10s seek within the clip
            // fromStart: continuous playback / manual skip should play the message from the
            // beginning (use ±10s to scrub within it), not resume a saved mid/end position.
            AudioPlayerService.shared.toggle(message: msg, bookId: currentBookId, fromStart: true)  // completion → advance
        case .text:
            let body = msg.body ?? ""
            isSpeakingTTS = true                      // before stopAll fires the observer
            updateNowPlaying(title: body, artist: msg.senderName, duration: 0)
            updateSkipButtons(voice: false)          // TTS isn't seekable
            // Pause (don't destroy) the voice player so the next voice message reuses it — a
            // fresh player after TTS re-handshakes the wireless transport and stutters.
            AudioPlayerService.shared.suspendPlayerKeepingSession()
            AudioPlayerService.shared.ensurePlaybackSession()
            currentUtterance = nil               // ignore any cancelled live-utterance callback
            synthesizer.stopSpeaking(at: .immediate)
            ttsPlayer?.stop(); ttsPlayer = nil
            // Render to a file and play it (keeps the live TTS engine off the CarPlay route).
            renderTTS("\(msg.senderName) says: \(body)")
        default:
            advance()   // skip photo/video/unknown
        }
    }

    private func advance() {
        playIndex += 1
        playCurrent()
    }

    private func stopPlayback() {
        isSpeakingTTS = false
        currentUtterance = nil
        ttsRenderToken = UUID()
        ttsPlayer?.stop(); ttsPlayer = nil
        AudioPlayerService.shared.stopAll()
        synthesizer.stopSpeaking(at: .immediate)
        // Keep the last message on the Now Playing screen but paused (rate 0) instead of
        // clearing it — CarPlay leaves its Now Playing button up regardless, so blanking the
        // info just yields an empty dialog when it's tapped.
        if !npInfo.isEmpty {
            npInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
            commitNowPlaying()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // Only the current utterance's natural completion should advance; a cancelled or
            // superseded utterance's callback is ignored so it can't override a manual skip.
            guard utterance === self.currentUtterance else { return }
            self.currentUtterance = nil
            self.isSpeakingTTS = false
            self.advance()
        }
    }

    // MARK: - TTS via file (keeps the live synth engine off the wireless CarPlay route)

    // Render the utterance offline to a temp file (no audio route touched), then play it like a
    // voice clip. Falls back to live speech only if rendering yields nothing playable.
    private func renderTTS(_ text: String) {
        let token = UUID()
        ttsRenderToken = token
        let utterance = AVSpeechUtterance(string: text)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-\(token.uuidString)").appendingPathExtension("caf")
        var file: AVAudioFile?
        var wroteAny = false
        renderSynth.write(utterance) { [weak self] buffer in
            guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                file = nil   // close/flush the file
                Task { @MainActor in
                    self.playRenderedTTS(at: url, token: token, text: text, rendered: wroteAny)
                }
                return
            }
            if file == nil {
                file = try? AVAudioFile(forWriting: url,
                                        settings: pcm.format.settings,
                                        commonFormat: pcm.format.commonFormat,
                                        interleaved: pcm.format.isInterleaved)
            }
            if (try? file?.write(from: pcm)) != nil { wroteAny = true }
        }
    }

    @MainActor
    private func playRenderedTTS(at url: URL, token: UUID, text: String, rendered: Bool) {
        // A newer text/skip superseded this render — drop it.
        guard token == ttsRenderToken, isSpeakingTTS else {
            try? FileManager.default.removeItem(at: url); return
        }
        if rendered, let player = try? AVAudioPlayer(contentsOf: url) {
            player.delegate = self
            player.prepareToPlay()
            ttsPlayer = player
            player.play()
        } else {
            // Rendering failed — fall back to the live synthesizer so the message is still read.
            try? FileManager.default.removeItem(at: url)
            let utterance = AVSpeechUtterance(string: text)
            currentUtterance = utterance
            synthesizer.speak(utterance)   // didFinish → advance
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let url = player.url
        Task { @MainActor in
            guard player === self.ttsPlayer else { return }
            self.ttsPlayer = nil
            self.isSpeakingTTS = false
            if let url { try? FileManager.default.removeItem(at: url) }
            self.advance()
        }
    }

    // MARK: - Now Playing + transport controls

    private func updateNowPlaying(title: String, artist: String, duration: Double) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            // 0 unless the item clock is actually advancing, so the system doesn't run the
            // scrubber ahead of the audio during route warmup and then snap it back; the
            // observers promote it to 1 once playback is really moving.
            MPNowPlayingInfoPropertyPlaybackRate: AudioPlayerService.shared.isAdvancing ? 1.0 : 0.0
        ]
        if let art = Self.nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = art }
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(AudioPlayerService.shared.currentSeconds)
        }
        npInfo = info
        commitNowPlaying()
    }

    // CarPlay has no draggable scrubber (Apple blocks free scrubbing while driving), so for
    // voice messages we surface ±10s skip buttons in the Now Playing custom button row. Text
    // (TTS) isn't seekable, so we clear them there.
    private func updateSkipButtons(voice: Bool) {
        guard voice else {
            CPNowPlayingTemplate.shared.updateNowPlayingButtons([])
            return
        }
        let back = CPNowPlayingImageButton(image: UIImage(systemName: "gobackward.10") ?? UIImage()) { [weak self] _ in
            self?.seekRelative(-10)
        }
        let fwd = CPNowPlayingImageButton(image: UIImage(systemName: "goforward.10") ?? UIImage()) { [weak self] _ in
            self?.seekRelative(10)
        }
        // Playback-speed button (#54): tap to cycle 1× → 1.5× → 2× → 3× → 1×. A slider isn't
        // appropriate while driving, so it's a tap-to-cycle button showing the current rate.
        let rate = CPNowPlayingImageButton(image: rateButtonImage(AudioPlayerService.shared.playbackRate)) { [weak self] _ in
            self?.cycleCarPlayRate()
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([back, fwd, rate])
    }

    private let carPlayRates: [Float] = [1.0, 1.5, 2.0, 3.0]

    // Advance to the next speed in the cycle, apply it (shared with the phone), and rebuild the
    // buttons so the rate button shows the new value.
    private func cycleCarPlayRate() {
        let cur = AudioPlayerService.shared.playbackRate
        let idx = carPlayRates.firstIndex(where: { abs($0 - cur) < 0.01 }) ?? -1
        AudioPlayerService.shared.setRate(carPlayRates[(idx + 1) % carPlayRates.count])
        updateSkipButtons(voice: true)
    }

    // Render the current rate ("1×", "1.5×", "2×"…) as a template image for the CarPlay button.
    private func rateButtonImage(_ rate: Float) -> UIImage {
        let text = BunnySpeedIcon.label(rate) as NSString
        let size = CGSize(width: 44, height: 44)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: text.length > 2 ? 15 : 19, weight: .semibold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: para
        ]
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            let h = text.size(withAttributes: attrs).height
            text.draw(in: CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h), withAttributes: attrs)
        }
        return img.withRenderingMode(.alwaysTemplate)
    }

    // Seek the currently-playing voice message by a relative number of seconds (clamped).
    private func seekRelative(_ delta: Double) {
        guard playQueue.indices.contains(playIndex) else { return }
        let msg = playQueue[playIndex]
        guard msg.type == .voice, let dur = msg.durationSeconds, dur > 0 else { return }
        let target = min(max(Double(AudioPlayerService.shared.currentSeconds) + delta, 0), Double(dur))
        AudioPlayerService.shared.seek(to: target / Double(dur))
        npInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = target
        commitNowPlaying()
    }

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.skip(1) ?? .commandFailed }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.skip(-1) ?? .commandFailed }
        // Scrubbing — voice only (text TTS isn't seekable).
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent,
                  self.playQueue.indices.contains(self.playIndex) else { return .commandFailed }
            let msg = self.playQueue[self.playIndex]
            guard msg.type == .voice, let dur = msg.durationSeconds, dur > 0 else { return .commandFailed }
            AudioPlayerService.shared.seek(to: e.positionTime / Double(dur))
            self.npInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = e.positionTime
            self.commitNowPlaying()
            return .success
        }
    }

    private func resume() {
        guard playQueue.indices.contains(playIndex) else { return }
        let msg = playQueue[playIndex]
        if msg.type == .text {
            if let p = ttsPlayer, !p.isPlaying { p.play() }
            else if synthesizer.isPaused { synthesizer.continueSpeaking() }
            else { playCurrent() }
        } else if msg.type == .voice {
            AudioPlayerService.shared.toggle(message: msg)
        }
    }

    private func pause() {
        AudioPlayerService.shared.pause()
        ttsPlayer?.pause()
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
        currentUtterance = nil
        ttsRenderToken = UUID()
        ttsPlayer?.stop(); ttsPlayer = nil
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
