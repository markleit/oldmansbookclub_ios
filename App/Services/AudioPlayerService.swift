import AVFoundation
import Combine
import UIKit

@MainActor
final class AudioPlayerService: ObservableObject {
    static let shared = AudioPlayerService()

    @Published private(set) var playingMessageId: UUID?
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentSeconds: Int = 0
    @Published var speakerEnabled: Bool = true
    @Published var isExternalRouteActive: Bool = false
    @Published var playbackRate: Float = 1.0

    var onPlaybackCompleted: ((UUID) -> Void)?

    private let availableRates: [Float] = [1.0, 2.0, 3.0, 4.0]
    private var player: AVPlayer?
    private var timerCancellable: AnyCancellable?
    private var routeCancellable: AnyCancellable?

    private init() {
        routeCancellable = NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateRouteState() }
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
        player?.pause()
        playingMessageId = nil
        timerCancellable?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func stopAll() {
        stopCurrentPlayer()
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

    func setSpeaker(_ enabled: Bool) {
        speakerEnabled = enabled
        if playingMessageId != nil { activateAudioSession() }
    }

    private func play(message: Message) {
        stopCurrentPlayer()
        guard let urlStr = message.mediaUrl, let url = URL(string: urlStr) else { return }
        player = AVPlayer(url: url)
        playingMessageId = message.id
        progress = 0
        currentSeconds = 0
        activateAudioSession()
        player?.rate = playbackRate
        UIApplication.shared.isIdleTimerDisabled = true
        startTimer()
    }

    private func stopCurrentPlayer() {
        timerCancellable?.cancel()
        player?.pause()
        player = nil
        playingMessageId = nil
        progress = 0
        currentSeconds = 0
        UIApplication.shared.isIdleTimerDisabled = false
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
            stopCurrentPlayer()
            if let id = completedId {
                onPlaybackCompleted?(id)
            }
        }
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
        if speakerEnabled { options.insert(.defaultToSpeaker) }
        try? session.setCategory(.playAndRecord, mode: .spokenAudio, options: options)
        try? session.setActive(true)
    }

    private func updateRouteState() {
        let externalPorts: Set<AVAudioSession.Port> = [
            .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .headphones
        ]
        let hasExternal = AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { externalPorts.contains($0.portType) }
        if hasExternal && speakerEnabled {
            speakerEnabled = false
            if playingMessageId != nil { activateAudioSession() }
        }
        isExternalRouteActive = hasExternal
    }
}
