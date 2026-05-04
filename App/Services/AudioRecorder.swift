import AVFoundation

final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var startTime: Date?

    var isRecording: Bool { recorder?.isRecording ?? false }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.record()
        startTime = Date()
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
}
