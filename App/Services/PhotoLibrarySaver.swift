import Foundation
import Photos
import UIKit

// Saves a chat photo or video into the user's Photos library (#193). Asks for add-only access —
// the app never reads the library — and saves the ORIGINAL bytes from blob storage rather than
// the chat's re-encoded cache copy, so the saved file keeps full quality.
enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case accessDenied
        case downloadFailed
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .accessDenied: return "Old Man's Book Club doesn't have permission to add to your Photos."
            case .downloadFailed: return "Couldn't download it. Check your connection and try again."
            case .saveFailed: return "Couldn't save to Photos."
            }
        }
    }

    enum Kind { case photo, video }

    static func save(_ kind: Kind, from url: URL) async throws {
        guard await requestAccess() else { throw SaveError.accessDenied }
        let file = try await MediaDownloader.localFile(for: url, defaultExtension: kind == .photo ? "jpg" : "mp4")
        defer { if file != url { try? FileManager.default.removeItem(at: file) } }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset()
                    .addResource(with: kind == .photo ? .photo : .video, fileURL: file, options: nil)
            }
        } catch {
            throw SaveError.saveFailed
        }
    }

    private static func requestAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited: return true
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return granted == .authorized || granted == .limited
        default: return false
        }
    }
}

// Pulls a chat media URL down to a temp file (already-local URLs are returned as-is). Shared by
// Save to Photos and the viewers' Share button — the share sheet needs a real file, not a remote
// SAS link, to offer "Save Image" / "Save Video".
enum MediaDownloader {
    static func localFile(for url: URL, defaultExtension: String) async throws -> URL {
        if url.isFileURL { return url }
        guard let (tmp, response) = try? await URLSession.shared.download(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PhotoLibrarySaver.SaveError.downloadFailed
        }
        let ext = url.pathExtension.isEmpty ? defaultExtension : url.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            throw PhotoLibrarySaver.SaveError.downloadFailed
        }
        return dest
    }
}

// Presents the system share sheet over whatever is frontmost (works from inside a
// fullScreenCover, where a SwiftUI .sheet would stack awkwardly on the player).
enum ShareSheet {
    @MainActor
    static func present(_ items: [Any], onDismiss: (() -> Void)? = nil) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onDismiss?() }
        if let popover = vc.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 60, width: 0, height: 0)
        }
        top.present(vc, animated: true)
    }
}
