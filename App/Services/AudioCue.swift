import AVFoundation

// Short "mic is open" chirp played when a voice recording starts — a two-way-radio
// style "go ahead" beep. The tone is generated in memory (no bundled asset) and
// played to completion BEFORE capture begins, so it never ends up in the recording.
@MainActor
final class AudioCue {
    static let shared = AudioCue()

    private var player: AVAudioPlayer?
    // Rising = "go ahead" (mic open). Falling = "over" (mic closed).
    private lazy var recordStartData: Data = AudioCue.chirp(tones: [(1174.66, 60), (1567.98, 60)])
    private lazy var recordStopData: Data = AudioCue.chirp(tones: [(1567.98, 55), (1174.66, 75)])

    // Plays the start chirp and returns once it has finished (~130ms). Callers start
    // the recorder after this so the beep precedes capture, walkie-talkie style.
    func playRecordStart() async {
        // Ensure the beep is audible regardless of the silent switch by routing it
        // through the playAndRecord session (the recorder reuses this category next).
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)

        guard let player = try? AVAudioPlayer(data: recordStartData) else { return }
        self.player = player
        player.prepareToPlay()
        player.play()
        try? await Task.sleep(for: .milliseconds(150))
    }

    // Plays the "over" chirp on recording close. Fire-and-forget: capture has already
    // ended (so it won't be recorded) and the send shouldn't wait on it. Deactivates
    // the session afterward, matching the recorder's own stop behavior.
    func playRecordStop() {
        Task { [weak self] in
            guard let self else { return }
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [])
            try? session.setActive(true)
            guard let player = try? AVAudioPlayer(data: self.recordStopData) else { return }
            self.player = player
            player.prepareToPlay()
            player.play()
            try? await Task.sleep(for: .milliseconds(180))
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
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
