import AVFoundation

final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var startTime: Date?

    var isRecording: Bool { recorder?.isRecording ?? false }

    // `startAt`, when provided, is an audio-device-clock time (AVAudioPlayer.deviceCurrentTime
    // base) at which capture should begin — used to start exactly after the "mic open" chirp
    // has finished leaving the output route, with no main-thread sleep (see AudioCue).
    func start(atTime startAt: TimeInterval? = nil) throws {
        let session = AVAudioSession.sharedInstance()
        // `.allowBluetooth` was renamed to `.allowBluetoothHFP` in the iOS 26 SDK;
        // gate on the compiler so this builds on the older Xcode CI uses too.
        #if compiler(>=6.2)
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
        #else
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        #endif
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            // 32 kHz (was 16 kHz): 16 kHz capped the audio band at 8 kHz (Nyquist), which
            // is what gave voice notes their slightly dull "telephony" character. 32 kHz
            // opens the band to 16 kHz and recovers the presence/air of natural speech.
            // Mono stays — there's one phone mic, so stereo would just duplicate the
            // channel and double the bytes for zero audible gain.
            AVSampleRateKey: 32000,
            AVNumberOfChannelsKey: 1,
            // Long-term-average VBR around 48 kbps (was 32 kbps CBR): the variable
            // allocation spends bits on speech and almost none on silence/pauses, so we
            // get better quality per byte while keeping file size (≈ egress, the cost
            // lever) predictable. ~48 kbps feeds the wider 32 kHz band without spreading
            // bits thin. .high tells the AAC encoder to use its better psychoacoustic
            // model. Net ≈1.5× today's bytes for clearly more natural voice.
            AVEncoderBitRateKey: 48000,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_LongTermAverage,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let newRecorder = try AVAudioRecorder(url: url, settings: settings)
        newRecorder.prepareToRecord()
        // record()/record(atTime:) return false if the session isn't ready; surface that as
        // an error instead of leaving a recorder that reports isRecording == false (which
        // would later make stop() return nil and silently drop the message).
        let started = startAt.map { newRecorder.record(atTime: $0) } ?? newRecorder.record()
        guard started else {
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to start recording."])
        }
        recorder = newRecorder
        // Measure duration from the moment capture actually begins. With record(atTime:) that
        // is `startAt`, which is in the future by the chirp pre-roll; offset the wall clock by
        // that gap (computed on the same device clock) so the gap isn't counted as audio.
        let preroll = startAt.map { max(0, $0 - newRecorder.deviceCurrentTime) } ?? 0
        startTime = Date().addingTimeInterval(preroll)
    }

    func stop() -> (url: URL, duration: Int)? {
        guard let recorder, recorder.isRecording, let start = startTime else { return nil }
        let duration = max(1, Int(Date().timeIntervalSince(start)))
        recorder.stop()
        let url = recorder.url
        self.recorder = nil
        self.startTime = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return (url, duration)
    }

    /// Abandon the current take without producing a message: stop capture, delete the
    /// partial temp file, and tear down the session. Used when the recording is
    /// interrupted by backgrounding or a call/Siri/alarm (#75) — a truncated, never-
    /// deliberately-finished take is the wrong thing to send, so it's discarded.
    /// Safe to call when not recording (no-op).
    func discard() {
        guard let recorder else { return }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        self.startTime = nil
        try? FileManager.default.removeItem(at: url)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
