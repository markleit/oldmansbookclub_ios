import Foundation
import Speech

// On-device, best-effort transcripts for voice messages, cached per message id so a
// reply quote can show "🎤 <first words…>" instead of just "Voice message". Local only
// (Apple Speech can't run server-side); persists across launches. If a device hasn't
// transcribed a given message, callers fall back to the generic "Voice message" label.
@MainActor
final class TranscriptStore: ObservableObject {
    static let shared = TranscriptStore()

    @Published private(set) var transcripts: [String: String] = [:]
    private var inFlight: Set<String> = []
    private let key = "voiceTranscripts"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            transcripts = decoded
        }
    }

    func text(for id: UUID) -> String? { transcripts[id.uuidString] }

    func store(_ text: String, for id: UUID) {
        guard !text.isEmpty else { return }
        let isNew = transcripts[id.uuidString] == nil
        transcripts[id.uuidString] = text
        if let data = try? JSONEncoder().encode(transcripts) {
            UserDefaults.standard.set(data, forKey: key)
        }
        // Share it server-side (set-once there) so replies quoting this voice message
        // show the transcript to everyone, not just devices that transcribed locally.
        if isNew {
            Task { try? await APIClient.shared.uploadTranscript(messageId: id, text: text) }
        }
    }

    // Kick off a best-effort transcription if we don't already have one. Idempotent and
    // in-flight-deduped; safe to call from onAppear. No-op if already cached.
    func transcribeIfNeeded(messageId: UUID, mediaUrlString: String?) {
        let k = messageId.uuidString
        guard transcripts[k] == nil, !inFlight.contains(k),
              let urlStr = mediaUrlString, let url = URL(string: urlStr) else { return }
        inFlight.insert(k)

        Task { [weak self] in
            defer { self?.inFlight.remove(k) }

            let status = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
            guard status == .authorized else { return }

            // Prefer the already-cached audio file; otherwise download it.
            let localURL: URL
            if let cached = AudioCache.shared.cachedFileURL(for: url) {
                localURL = cached
            } else if let (tmp, _) = try? await URLSession.shared.download(from: url) {
                let m4a = tmp.deletingPathExtension().appendingPathExtension("m4a")
                try? FileManager.default.moveItem(at: tmp, to: m4a)
                localURL = m4a
            } else { return }

            guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return }
            let request = SFSpeechURLRecognitionRequest(url: localURL)
            request.shouldReportPartialResults = false

            let result = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<SFSpeechRecognitionResult, Error>) in
                var finished = false
                recognizer.recognitionTask(with: request) { result, error in
                    guard !finished else { return }
                    if let error { finished = true; cont.resume(throwing: error) }
                    else if let result, result.isFinal { finished = true; cont.resume(returning: result) }
                }
            }
            if let text = result?.bestTranscription.formattedString {
                self?.store(text, for: messageId)
            }
        }
    }
}
