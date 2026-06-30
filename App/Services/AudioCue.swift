import AVFoundation

// Short "mic is open" chirp played when a voice recording starts — a two-way-radio
// style "go ahead" beep. The tone is generated in memory (no bundled asset) and
// played to completion BEFORE capture begins, so it never ends up in the recording.
@MainActor
final class AudioCue {
    static let shared = AudioCue()

    private var player: AVAudioPlayer?

    // User setting (Settings → "Recording Tones"), stored via @AppStorage under the
    // same key. Defaults to on when the key has never been written.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "micChirpEnabled") as? Bool ?? true
    }
    // Rising = "go ahead" (mic open). Falling = "over" (mic closed).
    private lazy var recordStartData: Data = AudioCue.chirp(tones: [(1174.66, 60), (1567.98, 60)])
    private lazy var recordStopData: Data = AudioCue.chirp(tones: [(1567.98, 55), (1174.66, 75)])

    // Plays the "mic open" chirp and returns the audio-device-clock time after which the
    // recorder may begin capturing without the tone bleeding in. The recorder schedules
    // its start at this exact tick via AVAudioRecorder.record(atTime:), which shares the
    // AVAudioPlayer.deviceCurrentTime clock — so the gap is enforced by the audio hardware,
    // not a main-thread sleep. The window is (chirp duration + route output latency): both
    // are queried values, so this holds on a bare phone and on a high-latency CarPlay/HFP
    // route alike, where a fixed delay let the tail bleed into the recording (#11).
    // Returns nil when the cue is disabled — the caller then starts capture immediately.
    func playRecordStart() -> TimeInterval? {
        guard AudioCue.isEnabled else { return nil }
        configureSessionForCue()
        guard let player = try? AVAudioPlayer(data: recordStartData) else { return nil }
        self.player = player
        player.prepareToPlay()
        // Schedule playback at a precise tick (small lead for scheduling headroom) so the
        // math below is exact rather than relative to an approximate "play now".
        let chirpStart = player.deviceCurrentTime + 0.05
        player.play(atTime: chirpStart)
        return chirpStart + player.duration + AVAudioSession.sharedInstance().outputLatency
    }

    // Plays the "over" chirp on recording close. Fire-and-forget: capture has already
    // ended (so it won't be recorded) and the send shouldn't wait on it. Deactivates
    // the session afterward, matching the recorder's own stop behavior.
    func playRecordStop() {
        guard AudioCue.isEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            // Use the SAME session config as the start chirp / recording (playAndRecord
            // + Bluetooth). The recorder just deactivated the session; on CarPlay the
            // HFP route is still warm, so reusing it plays the chirp immediately. The
            // old code switched to .playback (no BT options), which forced an HFP→A2DP
            // profile switch — ~1-2s on car head units — and the 180ms chirp was lost
            // in the gap (worked on AirPods, silent on CarPlay).
            self.configureSessionForCue()
            guard let player = try? AVAudioPlayer(data: self.recordStopData) else { return }
            self.player = player
            player.prepareToPlay()
            player.play()
            try? await Task.sleep(for: .milliseconds(180))
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // Shared session setup for both chirps so start + stop take the identical route
    // (no category flip between them). Configure playAndRecord + Bluetooth WITHOUT
    // forcing the speaker, activate so the real output resolves (AirPods/CarPlay/BT
    // take over — checking the route before activation can miss a not-yet-active one),
    // then override to the built-in speaker ONLY when there's no external route (so the
    // cue still beats the silent switch on a bare phone without hijacking a car/BT route).
    private func configureSessionForCue() {
        let session = AVAudioSession.sharedInstance()
        #if compiler(>=6.2)
        let btOptions: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP]
        #else
        let btOptions: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
        #endif
        try? session.setCategory(.playAndRecord, mode: .default, options: btOptions)
        try? session.setActive(true)
        if !AudioCue.hasExternalOutputRoute() {
            try? session.overrideOutputAudioPort(.speaker)
        }
    }

    // True when audio is routed somewhere other than the phone's own speaker/receiver
    // (CarPlay, Bluetooth, AirPlay, wired). On those routes we must NOT force the
    // built-in speaker, or the cue plays on the phone instead of the active route.
    private static func hasExternalOutputRoute() -> Bool {
        let external: Set<AVAudioSession.Port> = [
            .carAudio, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
            .airPlay, .headphones, .usbAudio, .lineOut
        ]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { external.contains($0.portType) }
    }

    // Two quick tones with short fades to avoid clicks.
    private static func chirp(tones: [(freq: Double, ms: Double)]) -> Data {
        let sampleRate = 44100.0
        let amplitude = 0.45
        var samples: [Int16] = []
        for tone in tones {
            let count = Int(sampleRate * tone.ms / 1000.0)
            let fade = sampleRate * 0.005  // 5ms attack/decay
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let env = min(1.0, min(Double(i), Double(count - i)) / fade)
                let v = sin(2.0 * .pi * tone.freq * t) * env * amplitude
                samples.append(Int16(max(-1.0, min(1.0, v)) * Double(Int16.max)))
            }
        }
        return wav(from: samples, sampleRate: Int(sampleRate))
    }

    // Wraps 16-bit mono PCM in a minimal WAV container.
    private static func wav(from samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        func append32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        let dataSize = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)                       // PCM fmt chunk size
        append16(1)                        // PCM
        append16(1)                        // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))   // byte rate (sampleRate * blockAlign)
        append16(2)                        // block align (mono * 16-bit)
        append16(16)                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataSize))
        for s in samples { var x = s.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        return data
    }
}
