import AVFoundation
import Combine
import UIKit

@MainActor
final class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()

    @Published private(set) var playingMessageId: UUID?
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentSeconds: Int = 0
    @Published private(set) var isBuffering: Bool = false
    @Published var playbackRate: Float = 1.0
    private var isExternalRouteActive: Bool = false

    var onPlaybackCompleted: ((UUID) -> Void)?

    private let availableRates: [Float] = [1.0, 1.5, 2.0, 3.0, 4.0]
    private var player: AVPlayer?
    private var timerCancellable: AnyCancellable?
    private var bufferCancellable: AnyCancellable?
    private var routeCancellable: AnyCancellable?
    private var proximityCancellable: AnyCancellable?
    private var isNearEar = false
    private var isUserInitiatedPause = false

    private init() {
        routeCancellable = NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.handleRouteChange(note) }
        updateRouteState()
    }

    func toggle(message: Message) {
        if playingMessageId == message.id {
            pause()
        } else {
            play(message: message)
        }
    }

    func cycleRate() {
        let currentIndex = availableRates.firstIndex(of: playbackRate) ?? 0
        playbackRate = availableRates[(currentIndex + 1) % availableRates.count]
        player?.rate = playbackRate
    }

    func pause() {
        saveCurrentPosition(completed: false)
        isUserInitiatedPause = true
        player?.pause()
        playingMessageId = nil
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

    private func play(message: Message) {
        saveCurrentPosition(completed: false)   // remember where the outgoing message was
        stopCurrentPlayer()
        guard let urlStr = message.mediaUrl, let url = URL(string: urlStr) else { return }

        // Resume from the saved position. Replaying a fully-played message starts over
        // and clears its green/completed state.
        let store = PlaybackProgressStore.shared
        var resume = store.position(for: message.id)
        if store.isCompleted(message.id) {
            store.clear(message.id)
            resume = 0
        }

        // Play the cached local file if we have it (instant start); otherwise stream the
        // remote blob and seed the cache so replays are instant.
        let playURL: URL
        if let cached = AudioCache.shared.cachedFileURL(for: url) {
            playURL = cached
        } else {
            playURL = url
            AudioCache.shared.prefetch(url)
        }
        let newPlayer = AVPlayer(url: playURL)
        player = newPlayer
        playingMessageId = message.id
        isUserInitiatedPause = false
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
        progress = min(current / duration, 1.0)
        currentSeconds = Int(current)
        if current >= duration - 0.05 {
            let completedId = playingMessageId
            saveCurrentPosition(completed: true)   // mark fully played (green)
            stopCurrentPlayer()
            if let id = completedId {
                onPlaybackCompleted?(id)
            }
        }
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // `.allowBluetooth` was renamed to `.allowBluetoothHFP` in the iOS 26 SDK
        // (Xcode 26 / Swift 6.2+). Gate on the compiler so this still builds on the
        // older Xcode the CI runner uses, while staying deprecation-warning-free on
        // the release toolchain.
        #if compiler(>=6.2)
        let btOptions: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP]
        #else
        let btOptions: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
        #endif
        if isNearEar && !isExternalRouteActive {
            // Earpiece path: requires playAndRecord to override default speaker routing
            try? session.setCategory(.playAndRecord, mode: .spokenAudio, options: btOptions)
        } else {
            // Speaker/BT path: playback gives full system volume (playAndRecord reduces gain)
            try? session.setCategory(.playback, mode: .spokenAudio, options: btOptions)
        }
        try? session.setActive(true)
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
            .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .headphones
        ]
        let hasExternal = AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { externalPorts.contains($0.portType) }
        isExternalRouteActive = hasExternal
        if playingMessageId != nil { activateAudioSession() }
    }
}
