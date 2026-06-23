import AVFoundation
import Combine
import UIKit

@MainActor
final class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()

    @Published private(set) var playingMessageId: UUID?
    // The book the currently-playing message belongs to. Published purely so other surfaces
    // (CarPlay) can locate the right chat to mirror — does not affect phone playback behavior.
    @Published private(set) var playingBookId: UUID?
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentSeconds: Int = 0
    @Published private(set) var isBuffering: Bool = false
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
    private var routeCancellable: AnyCancellable?
    private var proximityCancellable: AnyCancellable?
    private var isNearEar = false
    private var isUserInitiatedPause = false
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
        updateRouteState()
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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

    private func play(message: Message, bookId: UUID? = nil, fromStart: Bool = false) {
        saveCurrentPosition(completed: false)   // remember where the outgoing message was
        stopCurrentPlayer()                     // clears playingBookId — re-set it below
        guard let urlStr = message.mediaUrl, let url = URL(string: urlStr) else { return }

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
        print("🔊 play cached=\(isCached) route=\(Self.routeDesc())")
        let item = AVPlayerItem(url: playURL)
        // Pitch-preserving time stretch tuned for speech: .timeDomain keeps voice clear at
        // higher rates while being far cheaper than .spectral (which can cause skips at 2×/3×,
        // especially over wireless CarPlay).
        item.audioTimePitchAlgorithm = .timeDomain
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        playingMessageId = message.id
        playingBookId = bookId
        isUserInitiatedPause = false
        playingDurationSeconds = message.durationSeconds ?? 0
        let dur = Double(message.durationSeconds ?? 0)
        progress = (dur > 0 && resume > 0) ? min(resume / dur, 1) : 0
        currentSeconds = Int(resume)
        isBuffering = true
        if resume > 0.5 {
            newPlayer.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
        }
        activateAudioSession()
        enableProximityMonitoring()
        newPlayer.rate = playbackRate
        UIApplication.shared.isIdleTimerDisabled = true
        startTimer()
        var hasStartedPlaying = false
        bufferCancellable = newPlayer.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.isBuffering = (status == .waitingToPlayAtSpecifiedRate)
                print("🔊 status=\(status.rawValue) buffering=\(self.isBuffering) route=\(Self.routeDesc())")
                if status == .playing { hasStartedPlaying = true }
                if status == .paused, hasStartedPlaying, !self.isUserInitiatedPause, self.playingMessageId != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        guard let self, self.playingMessageId != nil, !self.isUserInitiatedPause else { return }
                        self.activateAudioSession()
                        self.player?.rate = self.playbackRate
                    }
                }
            }
    }

    private func stopCurrentPlayer(deactivateSession: Bool = true) {
        isUserInitiatedPause = true
        timerCancellable?.cancel()
        bufferCancellable?.cancel()
        player?.pause()
        player = nil
        playingMessageId = nil
        playingBookId = nil
        progress = 0
        currentSeconds = 0
        isBuffering = false
        UIApplication.shared.isIdleTimerDisabled = false
        disableProximityMonitoring()
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func startTimer() {
        timerCancellable = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard let player, let item = player.currentItem else { return }
        let duration = item.duration.seconds
        let current = player.currentTime().seconds
        guard duration.isFinite, duration > 0 else { return }
        // Display against the recorded total (if known) so the bar/counter never
        // overrun it; playback still completes at the real file end below.
        let displayTotal = playingDurationSeconds > 0 ? Double(playingDurationSeconds) : duration
        progress = min(current / displayTotal, 1.0)
        currentSeconds = min(Int(current), playingDurationSeconds > 0 ? playingDurationSeconds : Int(duration))
        if current >= duration - 0.05 {
            let completedId = playingMessageId
            saveCurrentPosition(completed: true)   // mark fully played (green)
            stopCurrentPlayer()
            if let id = completedId {
                onPlaybackCompleted?(id)        // side effects (mark-heard, UI)
                if let next = nextToPlay?(id) { // continuous playback / "play all"
                    play(message: next)
                }
            }
        }
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // A2DP only — deliberately NOT allowBluetoothHFP. HFP is the telephone-grade
        // (~8–16 kHz, bidirectional) Bluetooth profile; allowing it lets iOS route voice
        // playback over the car's HFP/phone channel instead of the high-quality CarPlay/A2DP
        // media path, which sounds far worse than other apps and is prone to skips.
        let btOptions: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]
        if isNearEar && !isExternalRouteActive {
            // Earpiece path: requires playAndRecord to override default speaker routing
            try? session.setCategory(.playAndRecord, mode: .spokenAudio, options: btOptions)
        } else {
            // Speaker/BT path: playback gives full system volume (playAndRecord reduces gain)
            try? session.setCategory(.playback, mode: .spokenAudio, options: btOptions)
        }
        try? session.setActive(true)
        print("🔊 activateSession nearEar=\(isNearEar) ext=\(isExternalRouteActive) -> route=\(Self.routeDesc())")
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
        isExternalRouteActive = hasExternal
        print("🔊 routeChange -> \(Self.routeDesc()) ext=\(hasExternal) playing=\(playingMessageId != nil)")
        if playingMessageId != nil { activateAudioSession() }
    }
}
