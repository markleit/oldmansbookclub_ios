import AVFoundation
import Combine
import UIKit
import OSLog

@MainActor
final class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()

    // Persistent audio diagnostics (the 🔊 traces) used to hunt the wireless-CarPlay skips —
    // read in Console.app, category "audio". Unlike print(), os_log survives without the debugger
    // attached, so it captures battery-mode skips. STRIPPED by default; re-enable by adding
    // AUDIO_DIAG to SWIFT_ACTIVE_COMPILATION_CONDITIONS in project.yml (then `xcodegen generate`).
    // The call sites stay in place — @autoclosure makes them zero-cost (the message, incl.
    // routeDesc(), isn't even evaluated) unless the flag is set.
    #if AUDIO_DIAG
    private static let audioLog = Logger(subsystem: "com.example.oldmansbookclub", category: "audio")
    #endif
    private static func alog(_ msg: @autoclosure () -> String) {
        #if AUDIO_DIAG
        audioLog.notice("\(msg(), privacy: .public)")
        #endif
    }

    // AVAudioSession setCategory/setActive do synchronous IPC with the audio daemon. On the
    // main thread iOS flags that as a performance antipattern ("non-deterministic delays"),
    // and it can stall the CarPlay scene enough to drop the connection (audio skips). Run all
    // session IPC on a dedicated serial queue (serial = ordering preserved) off the main thread.
    // .userInitiated so a high-QoS (audio) thread doesn't block waiting on this lower-priority
    // queue — the device trace flagged exactly that priority inversion, lining up with ~660ms
    // source stalls (airplayd starvation).
    private static let sessionQueue = DispatchQueue(label: "com.example.oldmansbookclub.audiosession", qos: .userInitiated)

    @Published private(set) var playingMessageId: UUID?
    // The book the currently-playing message belongs to. Published purely so other surfaces
    // (CarPlay) can locate the right chat to mirror — does not affect phone playback behavior.
    @Published private(set) var playingBookId: UUID?
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentSeconds: Int = 0
    @Published private(set) var isBuffering: Bool = false
    // True only while the item's PLAYBACK CLOCK is actually advancing between ticks. This is the
    // signal CarPlay uses to run the Now Playing scrubber (rate 1). timeControlStatus == .playing
    // is NOT enough: with automaticallyWaitsToMinimizeStalling = false, playImmediately reports
    // .playing during the route warmup while the clock is still pinned at 0, so the system would
    // extrapolate the scrubber ahead and then snap it back when real playback starts.
    @Published private(set) var isAdvancing: Bool = false
    // Continuous 1–4× voice playback speed, persisted across launches.
    private static let rateKey = "voicePlaybackRate"
    @Published var playbackRate: Float = {
        let v = UserDefaults.standard.float(forKey: AudioPlayerService.rateKey)   // 0 if unset
        return (v >= 1.0 && v <= 4.0) ? v : 1.0
    }() {
        didSet {
            UserDefaults.standard.set(playbackRate, forKey: Self.rateKey)
            player?.rate = playbackRate
        }
    }
    private var isExternalRouteActive: Bool = false
    // Keep the audio session active across the whole continuous-playback queue (like Spotify)
    // rather than tearing it down + rebuilding per message — per-message session churn
    // destabilizes the wireless CarPlay route and causes intermittent skips.
    private var audioSessionActive = false
    private var sessionUsesEarpiece = false

    // Fired when a message finishes — for side effects (mark-heard, UI). Distinct from
    // auto-advance below.
    var onPlaybackCompleted: ((UUID) -> Void)?
    // Auto-advance provider: given the just-finished message id, return the next message
    // to play (or nil to stop). Lets different surfaces own their own play queue without
    // fighting over a single completion callback — the chat advances through visible
    // messages; CarPlay advances through its "play all unheard" queue.
    var nextToPlay: ((UUID) -> Message?)?

    private var player: AVPlayer?
    private var timerCancellable: AnyCancellable?
    private var bufferCancellable: AnyCancellable?
    // Authoritative end-of-item + load-failure signals for the item currently playing. The polling
    // clock in tick() is the primary completion path; these are the backstops that keep the
    // auto-advance queue moving if the clock misses the end or the item can't load (#93).
    private var endCancellable: AnyCancellable?
    private var failCancellable: AnyCancellable?
    // The item we've already advanced past — dedupes the clock, the didPlayToEnd notification, and a
    // load failure so they can't advance more than once for the same item.
    private weak var lastResolvedItem: AVPlayerItem?
    // Set when an explicit reposition happens (new message, resume seek, user seek/skip) so the
    // next tick may accept a backward time. Otherwise tick rejects backward jumps, which are the
    // reused player reporting a stale ~0 time after replaceCurrentItem (the timer "restart").
    // Last item-clock reading, to detect whether playback is actually advancing (drives isAdvancing).
    private var lastAdvanceCheckTime: Double = -1
    private var routeCancellable: AnyCancellable?
    private var interruptionCancellable: AnyCancellable?
    private var proximityCancellable: AnyCancellable?
    private var isNearEar = false
    private var isUserInitiatedPause = false
    // True between an audio-session interruption's .began and .ended (incoming call, Siri, another
    // app like Spotify taking the session). While set, the stall-recovery must NOT auto-resume —
    // otherwise we fight the interruption and keep talking over the call/other audio.
    private var isInterrupted = false
    // The message's recorded length. AVPlayer's item.duration for AAC/m4a can run
    // longer than the audible content, making the counter overshoot the displayed
    // total. We keep playing to the real file end but clamp the published
    // progress/currentSeconds to this so the UI never shows more than the total.
    private var playingDurationSeconds: Int = 0

    private init() {
        routeCancellable = NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.handleRouteChange(note) }
        // Pause on interruptions (calls/Siri/other apps) and resume only when the system says so.
        // Lives here (not in a view model) so it also covers CarPlay-driven playback.
        interruptionCancellable = NotificationCenter.default
            .publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.handleInterruption(note) }
        updateRouteState()
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            guard playingMessageId != nil else { return }
            // Suspend playback but KEEP the message/position so .ended can resume it. Marking
            // isInterrupted stops the .paused stall-recovery from immediately resuming over the
            // interruption. The player paused → tick stops advancing → Now Playing shows paused.
            isInterrupted = true
            saveCurrentPosition(completed: false)
            player?.pause()
            isAdvancing = false
            isBuffering = false
        case .ended:
            guard isInterrupted else { return }
            isInterrupted = false
            let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            // Only resume if the system grants it (e.g. call ended) and we still have a message.
            if opts.contains(.shouldResume), playingMessageId != nil {
                activateAudioSession()
                player?.playImmediately(atRate: playbackRate)
            }
        @unknown default:
            break
        }
    }

    func toggle(message: Message, bookId: UUID? = nil, fromStart: Bool = false) {
        if playingMessageId == message.id {
            pause()
        } else {
            play(message: message, bookId: bookId, fromStart: fromStart)
        }
    }

    // Set a continuous playback rate, clamped to 1–4×. Persisted + applied live via the
    // playbackRate didSet.
    func setRate(_ rate: Float) {
        playbackRate = min(max(rate, 1.0), 4.0)
    }

    func pause() {
        saveCurrentPosition(completed: false)
        isUserInitiatedPause = true
        player?.pause()
        playingMessageId = nil
        playingBookId = nil
        timerCancellable?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
        disableProximityMonitoring()
        deactivateAudioSession()
    }

    // Persist the playing message's position so it can be resumed later. `completed`
    // marks it fully played (green); otherwise saves the current elapsed time.
    private func saveCurrentPosition(completed: Bool) {
        guard let id = playingMessageId, let player, let item = player.currentItem else { return }
        let dur = item.duration.seconds
        let cur = player.currentTime().seconds
        guard dur.isFinite, dur > 0, cur.isFinite else { return }
        PlaybackProgressStore.shared.set(
            id: id,
            position: completed ? dur : min(max(cur, 0), dur),
            completed: completed
        )
    }

    // deactivateSession: pass false when the caller is about to immediately
    // reconfigure + reactivate the session itself (e.g. starting a recording).
    // Deactivating here and reactivating microseconds later races the audio
    // session and can make AVAudioRecorder.record() silently fail.
    func stopAll(deactivateSession: Bool = true) {
        saveCurrentPosition(completed: false)
        stopCurrentPlayer(deactivateSession: deactivateSession)
    }

    func seek(to fraction: Double) {
        guard let player, let item = player.currentItem else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        let time = CMTime(seconds: duration * max(0, min(1, fraction)), preferredTimescale: 600)
        player.seek(to: time)
        progress = fraction
        currentSeconds = Int(duration * fraction)
    }

    // Activate + configure the playback session (idempotent, same .default config as voice).
    // For audio played outside the AVPlayer path — CarPlay TTS — so it doesn't leave the
    // session on a different mode that the idempotent activate won't correct, which made
    // voice messages played after a spoken text message skip.
    func ensurePlaybackSession() {
        activateAudioSession()
    }

    // Pause the AVPlayer but KEEP it (and the session) alive — for surfaces that briefly take
    // over the output (CarPlay TTS). Destroying the player (stopAll) makes the next voice
    // message build a fresh AVPlayer, which re-handshakes the wireless transport (airplayd) and
    // stutters. Pausing keeps the stream connected so the next voice reuses it seamlessly.
    func suspendPlayerKeepingSession() {
        saveCurrentPosition(completed: false)
        player?.pause()
        playingMessageId = nil
        playingBookId = nil
        timerCancellable?.cancel()
        isBuffering = false
        Self.alog("🔊 suspend keepPlayer=\(player != nil)")
    }

    private func play(message: Message, bookId: UUID? = nil, fromStart: Bool = false) {
        saveCurrentPosition(completed: false)   // remember where the outgoing message was
        guard let urlStr = message.mediaUrl, let url = URL(string: urlStr) else {
            stopCurrentPlayer(deactivateSession: false); return
        }
        // Reuse ONE AVPlayer across messages (replaceCurrentItem) instead of building a new one
        // per message. A fresh AVPlayer re-handshakes the wireless CarPlay audio transport
        // (airplayd) — ~500ms during which airplayd has no source and skips. Reusing the player
        // keeps that stream alive. Tear down the outgoing item's observers/timer but NOT the
        // player itself.
        timerCancellable?.cancel()
        bufferCancellable?.cancel()
        isUserInitiatedPause = false
        isInterrupted = false   // a fresh play is not an interrupted one

        // Resume from the saved position. Replaying a fully-played message starts over
        // from the beginning but stays "heard" (green is sticky). fromStart forces the
        // beginning regardless (used by CarPlay's continuous playback / manual skip, where a
        // resume that's already at the end would instantly complete and skip the message).
        let store = PlaybackProgressStore.shared
        var resume = store.position(for: message.id)
        if fromStart {
            resume = 0
        } else if store.isCompleted(message.id) {
            store.resetPosition(message.id)
            resume = 0
        }

        // Play the cached local file if we have it (instant start); otherwise stream the
        // remote blob and seed the cache so replays are instant.
        let playURL: URL
        let isCached: Bool
        if let cached = AudioCache.shared.cachedFileURL(for: url) {
            playURL = cached
            isCached = true
        } else {
            playURL = url
            isCached = false
            AudioCache.shared.prefetch(url)
        }
        let item = AVPlayerItem(url: playURL)
        // Pitch-preserving time stretch tuned for speech: .timeDomain keeps voice clear at
        // higher rates while being far cheaper than .spectral (which can cause skips at 2×/3×,
        // especially over wireless CarPlay).
        item.audioTimePitchAlgorithm = .timeDomain
        let reusing = player != nil
        let activePlayer: AVPlayer
        if let existing = player {
            existing.replaceCurrentItem(with: item)
            activePlayer = existing
        } else {
            activePlayer = AVPlayer(playerItem: item)
            player = activePlayer
        }
        // Local cached files don't need stall-minimization buffering — and that buffering makes
        // AVPlayer stop/restart its audio I/O engine, starving the wireless CarPlay transport
        // (airplayd) → skips. Play immediately and keep the I/O running.
        activePlayer.automaticallyWaitsToMinimizeStalling = false
        Self.alog("🔊 play cached=\(isCached) reuse=\(reusing) route=\(Self.routeDesc())")
        playingMessageId = message.id
        playingBookId = bookId
        playingDurationSeconds = message.durationSeconds ?? 0
        let dur = Double(message.durationSeconds ?? 0)
        progress = (dur > 0 && resume > 0) ? min(resume / dur, 1) : 0
        currentSeconds = Int(resume)
        lastAdvanceCheckTime = resume   // don't count the resume jump as "advancing"
        isAdvancing = false
        isBuffering = true
        if resume > 0.5 {
            activePlayer.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
        }
        activateAudioSession()
        enableProximityMonitoring()
        activePlayer.playImmediately(atRate: playbackRate)   // start now, don't wait to buffer
        // Only keep the PHONE screen awake for on-device playback. On an external route
        // (CarPlay/BT) the screen doesn't need to be on — and keeping it on while driving drives
        // constant brightness/HDR/flicker work that competes with audio over the wireless link
        // (the `audio` background mode keeps playback alive with the screen asleep).
        UIApplication.shared.isIdleTimerDisabled = !isExternalRouteActive
        startTimer()
        var hasStartedPlaying = false
        bufferCancellable = activePlayer.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.isBuffering = (status == .waitingToPlayAtSpecifiedRate)
                if status != .playing { self.isAdvancing = false }   // tick promotes once the clock moves
                Self.alog("🔊 status=\(status.rawValue) buffering=\(self.isBuffering) route=\(Self.routeDesc())")
                if status == .playing { hasStartedPlaying = true }
                if status == .paused, hasStartedPlaying, !self.isUserInitiatedPause, !self.isInterrupted, self.playingMessageId != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        guard let self, self.playingMessageId != nil, !self.isUserInitiatedPause, !self.isInterrupted else { return }
                        // On external routes (CarPlay/BT) don't re-activate the whole session —
                        // that disrupts the wireless audio link and cascades into skips. Just nudge
                        // the player to resume; AVPlayer recovers from transient stalls on its own.
                        if !self.isExternalRouteActive { self.activateAudioSession() }
                        self.player?.rate = self.playbackRate
                    }
                }
            }
        // Authoritative "this item is done" signal. tick()'s polling clock is the primary path, but
        // if it misses the end (timer starvation / a pause-at-end race) this still advances the queue.
        endCancellable = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.advancePast(item, heard: true) }
        // The item couldn't load (e.g. a stale streaming URL) or failed mid-playback. Skip past it
        // instead of spinning forever on `guard item.status == .readyToPlay` in tick() (#93). A
        // skipped item is NOT marked heard, so it stays unheard and can be retried after a refresh.
        failCancellable = Publishers.Merge(
            item.publisher(for: \.status).filter { $0 == .failed }.map { _ in () },
            NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item).map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.advancePast(item, heard: false) }
    }

    // Single funnel for leaving the current item — whether it finished cleanly (heard) or failed to
    // load/play (skip). Guarded by item identity so the polling clock, the didPlayToEnd
    // notification, and a load failure can't advance more than once for the same item.
    private func advancePast(_ item: AVPlayerItem?, heard: Bool) {
        guard let item, item === player?.currentItem, item !== lastResolvedItem else { return }
        lastResolvedItem = item
        guard let finishedId = playingMessageId else { return }
        if heard {
            saveCurrentPosition(completed: true)   // mark fully played (green)
            onPlaybackCompleted?(finishedId)       // mark-heard / UI side effects (CarPlay advance too)
        } else {
            Self.alog("🔊 item failed/stalled id=\(finishedId) — skipping to next")
        }
        // Reuse the player for the next message (replaceCurrentItem) to keep the wireless CarPlay
        // transport stream alive across the boundary.
        if playingMessageId == finishedId, let next = nextToPlay?(finishedId) {
            play(message: next)
        }
        // Nothing advanced (end of queue) — now tear down + release the session.
        if playingMessageId == finishedId {
            stopCurrentPlayer(deactivateSession: false)
            deactivateAudioSession()
        }
    }

    private func stopCurrentPlayer(deactivateSession: Bool = true) {
        Self.alog("🔊 destroyPlayer deactivate=\(deactivateSession) hadPlayer=\(player != nil)")
        isUserInitiatedPause = true
        timerCancellable?.cancel()
        bufferCancellable?.cancel()
        endCancellable?.cancel()
        failCancellable?.cancel()
        player?.pause()
        player = nil
        playingMessageId = nil
        playingBookId = nil
        progress = 0
        currentSeconds = 0
        isBuffering = false
        isAdvancing = false
        isInterrupted = false
        lastAdvanceCheckTime = -1
        UIApplication.shared.isIdleTimerDisabled = false
        disableProximityMonitoring()
        if deactivateSession {
            deactivateAudioSession()
        }
    }

    private func startTimer() {
        timerCancellable = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard let player, let item = player.currentItem else { return }
        // After replaceCurrentItem (we reuse one player to keep the CarPlay stream alive), the new
        // item's clock isn't valid for a moment and the player can briefly report the PREVIOUS
        // item's (large) time. That made the progress bar jump and snap back to 0 — the visible
        // "restart" — even though the audio stream itself plays through fine, and it could trip the
        // completion check early. Wait until the item is actually ready, and read the item's own
        // clock (item.currentTime) rather than the player's shared one.
        guard item.status == .readyToPlay else { return }
        let duration = item.duration.seconds
        let current = item.currentTime().seconds
        guard duration.isFinite, duration > 0, current.isFinite, current >= 0 else { return }
        // The clock advanced since the last tick → audio is really playing (not just claiming to
        // during warmup). CarPlay gates the Now Playing rate on this so the scrubber never runs
        // ahead of the audio and snaps back.
        isAdvancing = current > lastAdvanceCheckTime + 0.02
        lastAdvanceCheckTime = current
        // Display against the recorded total (if known) so the bar/counter never
        // overrun it; playback still completes at the real file end below.
        let displayTotal = playingDurationSeconds > 0 ? Double(playingDurationSeconds) : duration
        progress = min(current / displayTotal, 1.0)
        currentSeconds = min(Int(current), playingDurationSeconds > 0 ? playingDurationSeconds : Int(duration))
        if current >= duration - 0.05 {
            advancePast(item, heard: true)
        }
    }

    private func activateAudioSession() {
        let useEarpiece = isNearEar && !isExternalRouteActive
        // Only (re)set the category on first activation or when the earpiece/speaker decision
        // changes. Re-setting it every message re-evaluates the route and churns the wireless
        // CarPlay link → skips. A2DP only — deliberately NOT allowBluetoothHFP (the
        // telephone-grade profile that made voice route over the car's phone channel).
        // .default (not .spokenAudio) matches music apps; .spokenAudio is more dropout-prone.
        let reconfigured = !audioSessionActive || useEarpiece != sessionUsesEarpiece
        if reconfigured { sessionUsesEarpiece = useEarpiece }
        audioSessionActive = true
        Self.alog("🔊 activateSession reconfigured=\(reconfigured) ext=\(isExternalRouteActive)")
        // Session IPC off the main thread (see sessionQueue note) — setActive on main can stall
        // the CarPlay scene and drop the connection.
        Self.sessionQueue.async {
            let session = AVAudioSession.sharedInstance()
            if reconfigured {
                let btOptions: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]
                if useEarpiece {
                    try? session.setCategory(.playAndRecord, mode: .spokenAudio, options: btOptions)
                } else {
                    try? session.setCategory(.playback, mode: .default, options: btOptions)
                }
            }
            try? session.setActive(true)
        }
    }

    // Deactivate the session off the main thread (same reason as activateAudioSession).
    private func deactivateAudioSession() {
        audioSessionActive = false
        Self.sessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // Describes the current audio output route (port types) — for diagnosing CarPlay routing.
    static func routeDesc() -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portType.rawValue)" }.joined(separator: ",")
    }

    private func enableProximityMonitoring() {
        UIDevice.current.isProximityMonitoringEnabled = true
        proximityCancellable = NotificationCenter.default
            .publisher(for: UIDevice.proximityStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.isNearEar = UIDevice.current.proximityState
                self.activateAudioSession()
            }
    }

    private func disableProximityMonitoring() {
        UIDevice.current.isProximityMonitoringEnabled = false
        proximityCancellable?.cancel()
        proximityCancellable = nil
        isNearEar = false
    }

    private func handleRouteChange(_ notification: Notification) {
        let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        if let r = reason, AVAudioSession.RouteChangeReason(rawValue: r) == .categoryChange { return }
        updateRouteState()
    }

    private func updateRouteState() {
        let externalPorts: Set<AVAudioSession.Port> = [
            .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .headphones, .carAudio
        ]
        let hasExternal = AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { externalPorts.contains($0.portType) }
        let was = isExternalRouteActive
        isExternalRouteActive = hasExternal
        Self.alog("🔊 routeChange -> \(Self.routeDesc()) ext=\(hasExternal) changed=\(was != hasExternal) playing=\(playingMessageId != nil)")
        // Only reconfigure the session when the route's external-ness actually changes. Wireless
        // CarPlay fires frequent route-change notifications; re-activating (setCategory+setActive)
        // on each one disrupts the audio link and causes skips on battery (Spotify etc. configure
        // once and leave it).
        if playingMessageId != nil && was != hasExternal { activateAudioSession() }
    }
}
