import Foundation

/// Uploads media blobs on a background `URLSession` so a send started right before the
/// app is suspended — or even killed — still completes: the OS runs the PUT out of process
/// and relaunches the app to deliver completion if needed (#70/#72, the suspend/kill case
/// beyond the ~30s window the foreground BackgroundTaskBox covers).
///
/// Only the blob PUT runs here. The PUT targets an Azure SAS URL, so no auth/token is
/// involved. On success we persist `uploadedMediaUrl` on the queue item and post
/// `.mediaUploadCompleted`; the SignalR invoke (which can't run while suspended) is left to
/// the normal foreground flush (BookViewModel.flushPendingMedia), which skips straight to the
/// invoke when `uploadedMediaUrl` is already set.
///
/// Task ↔ queue-item correlation rides in `taskDescription` ("<itemId>|<mediaUrl>"), which
/// nsurlsessiond persists across app relaunch.
final class BackgroundUploadService: NSObject {
    static let shared = BackgroundUploadService()

    static let sessionIdentifier = "com.markleit.oldmansbookclub.mediaupload"

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false            // chat messages should go promptly, not when the OS feels like it
        config.sessionSendsLaunchEvents = true     // relaunch the app to finish/deliver if it was killed
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // System completion handler from AppDelegate's handleEventsForBackgroundURLSession,
    // invoked once all delegate events for a background relaunch have been delivered.
    private var backgroundCompletionHandler: (() -> Void)?

    private override init() { super.init() }

    /// Recreate the session at launch so queued/finished background tasks deliver their
    /// delegate callbacks (marking items uploaded). Cheap; the lazy session is built once.
    func activate() { _ = session }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
        guard identifier == Self.sessionIdentifier else { return }
        backgroundCompletionHandler = handler
    }

    /// Start (or no-op if one is already in flight) a background PUT of `fileUrl` to the
    /// SAS `uploadUrl`. `mediaUrl` is the referenceable blob URL recorded on success.
    func upload(itemId: UUID, fileUrl: URL, uploadUrl: URL, mediaUrl: String, contentType: String) {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileUrl.path)[.size] as? Int) ?? 0
        var request = URLRequest(url: uploadUrl)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")
        request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        let task = session.uploadTask(with: request, fromFile: fileUrl)
        task.taskDescription = "\(itemId.uuidString)|\(mediaUrl)"
        task.resume()
    }

    /// Start background uploads for any queued media that isn't uploaded yet and has no
    /// upload already in flight — so the blob bytes move on app launch/foreground regardless
    /// of which screen is open, instead of waiting for the user to open that book's chat.
    /// The (cheap) SignalR invoke still lands when the matching chat connects (D's flush /
    /// handleUploadCompleted). `getUploadUrl` needs auth, so this no-ops when signed out.
    @MainActor
    func resumePendingUploads() async {
        guard TokenStore.shared.token != nil else { return }
        for item in MediaSendQueue.shared.items where item.uploadedMediaUrl == nil {
            if await hasInflightUpload(itemId: item.id) { continue }
            guard FileManager.default.fileExists(atPath: item.localFileUrl.path) else { continue }
            do {
                let ext = (item.fileName as NSString).pathExtension
                let response = try await APIClient.shared.getUploadUrl(clubId: item.clubId, ext: ext.isEmpty ? nil : ext)
                guard let uploadUrl = URL(string: response.uploadUrl) else { continue }
                upload(itemId: item.id, fileUrl: item.localFileUrl, uploadUrl: uploadUrl,
                       mediaUrl: response.mediaUrl, contentType: item.contentType)
            } catch {
                continue   // transient (e.g. auth/network) — retried on the next launch/foreground
            }
        }
    }

    /// Whether a background upload for this item is already running/queued — guards the send
    /// path from kicking a second PUT for the same item (e.g. a flush racing the first send).
    func hasInflightUpload(itemId: UUID) async -> Bool {
        let prefix = itemId.uuidString + "|"
        let tasks: [URLSessionTask] = await withCheckedContinuation { cont in
            session.getAllTasks { cont.resume(returning: $0) }
        }
        return tasks.contains {
            ($0.taskDescription?.hasPrefix(prefix) ?? false) && ($0.state == .running || $0.state == .suspended)
        }
    }
}

extension BackgroundUploadService: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let desc = task.taskDescription else { return }
        let parts = desc.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let itemId = UUID(uuidString: parts[0]) else { return }
        let mediaUrl = parts[1]

        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        let success = error == nil && (200..<300).contains(status)

        Task { @MainActor in
            guard success else {
                // Leave uploadedMediaUrl nil; the next flush re-fetches a fresh SAS and re-uploads.
                MediaSendQueue.shared.incrementRetry(id: itemId)
                NotificationCenter.default.post(name: .mediaUploadCompleted,
                                                object: nil, userInfo: ["itemId": itemId, "success": false])
                return
            }
            MediaSendQueue.shared.markUploaded(id: itemId, mediaUrl: mediaUrl)
            NotificationCenter.default.post(name: .mediaUploadCompleted,
                                            object: nil, userInfo: ["itemId": itemId, "success": true])
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }
}

extension Notification.Name {
    /// Posted (main thread) when a background media upload finishes; userInfo carries
    /// `itemId: UUID` and `success: Bool`. The active BookViewModel flushes to drive the invoke.
    static let mediaUploadCompleted = Notification.Name("MediaUploadCompleted")
}
