import AVFoundation

final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var startTime: Date?

    var isRecording: Bool { recorder?.isRecording ?? false }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ]

        let newRecorder = try AVAudioRecorder(url: url, settings: settings)
        // record() returns false if the session isn't ready; surface that as an
        // error instead of leaving a recorder that reports isRecording == false
        // (which would later make stop() return nil and silently drop the message).
        guard newRecorder.record() else {
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to start recording."])
        }
        recorder = newRecorder
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
