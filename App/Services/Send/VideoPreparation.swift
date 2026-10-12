import AVFoundation
import Foundation

// #204 design v2 — a picked video is made ready in the composer, before Send: checked, then
// compressed. Send waits until it's ready, so a sent video is complete at the tap — handed to iOS
// at once like a photo, even offline (2.2 (6): compressing after the tap meant a video whose user
// left the app first reached iOS only from the background, which iOS treats as low priority).
// Every refusal (too long, too large) is shown here, before anything is sent.
enum VideoPreparation {
    enum Outcome: Equatable {
        /// Ready to send: the compressed copy (a temporary file), or the original if it can't be
        /// compressed.
        case ready(URL, compressed: Bool)
        /// Can't be sent, with the reason to show.
        case refused(String)
        /// Stopped part-way — the app left the foreground. Started again when it's back.
        case interrupted
    }

    static let maxDuration: TimeInterval = 300

    static func prepare(_ source: URL,
                        duration: (URL) async -> TimeInterval?,
                        compress: (URL, @escaping (Double) -> Void) async -> VideoCompression,
                        size: (URL) -> Int64,
                        progress: @escaping (Double) -> Void) async -> Outcome {
        if let seconds = await duration(source), seconds > maxDuration {
            return .refused("Video is too long (max 5 minutes). Please trim it and try again.")
        }
        let tooLarge = "Video is too large (max 100 MB)."
        switch await compress(source, progress) {
        case .compressed(let url):
            guard size(url) <= SendItem.maxVideoBytes else {
                try? FileManager.default.removeItem(at: url)
                return .refused(tooLarge)
            }
            return .ready(url, compressed: true)
        case .unsupported:
            return size(source) <= SendItem.maxVideoBytes ? .ready(source, compressed: false) : .refused(tooLarge)
        case .interrupted:
            return .interrupted
        }
    }

    /// The real thing: AVFoundation's duration, VideoCompressor, the file's size on disk.
    static func prepare(_ source: URL, progress: @escaping (Double) -> Void) async -> Outcome {
        await prepare(source,
                      duration: { (try? await AVURLAsset(url: $0).load(.duration))?.seconds },
                      compress: { await VideoCompressor.compress($0, progress: $1) },
                      size: { ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.size]) as? Int64) ?? 0 },
                      progress: progress)
    }
}
