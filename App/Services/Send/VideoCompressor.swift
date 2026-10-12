import AVFoundation
import UIKit

/// What compressing a queued video came to (#204 PR 5).
enum VideoCompression {
    /// The compressed copy, in a temporary file the engine moves into the outbox.
    case compressed(URL)
    /// Can't be compressed (no preset fits, or the export failed): send the original.
    case unsupported
    /// Stopped part-way — the app was suspended. Start again from the original next time.
    case interrupted
}

/// #146 — HEVC 1080p, matching photos' "resize before upload". Moved out of the chat screen in
/// #204 PR 5: the engine compresses a video after it's queued, so the composer is free at once.
///
/// Caps resolution rather than targeting a bitrate: AVAssetExportSession doesn't upscale, so an
/// already-small source passes through roughly unchanged, while a 1080p/4K phone recording — the
/// common case that blew past the 100 MB cap — gets meaningfully smaller. HEVC rather than the
/// H.264 720p preset this started as: H.264 at 720p is ~3 Mbps, visibly softer and still ~110 MB
/// over a full 5-minute clip; HEVC 1080p is ~2.5 Mbps and lands nearer 94 MB at the duration
/// limit. AVPlayer has played HEVC since iOS 11. Falls back to the H.264 preset if HEVC isn't
/// available for this asset.
enum VideoCompressor {
    static func compress(_ source: URL) async -> VideoCompression {
        let asset = AVURLAsset(url: source)
        let preset = AVAssetExportSession.exportPresets(compatibleWith: asset)
            .contains(AVAssetExportPresetHEVC1920x1080)
            ? AVAssetExportPresetHEVC1920x1080
            : AVAssetExportPreset1920x1080
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { return .unsupported }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        export.outputURL = output
        export.outputFileType = .mp4
        // The completion-handler API, not iOS 18's `export(to:as:)`: the deployment target is 16.
        await withCheckedContinuation { continuation in
            export.exportAsynchronously { continuation.resume() }
        }
        if export.status == .completed { return .compressed(output) }
        try? FileManager.default.removeItem(at: output)
        // An export iOS stopped because the app left the foreground is worth trying again; a
        // failure with the app in front is the asset's, so the original goes instead.
        let wasInterrupted = export.status == .cancelled
            || (export.error as? AVError)?.code == .operationInterrupted
            || (export.error as? AVError)?.code == .sessionWasInterrupted
            || UIApplication.shared.applicationState != .active
        return wasInterrupted ? .interrupted : .unsupported
    }
}
