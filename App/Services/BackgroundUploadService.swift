import Foundation

/// #204 — what's left of the 2.1 send path: a one-time BRIDGE for transfers 2.1 handed to iOS just
/// before the app was updated to 2.2. Sending now belongs to SendEngine (its own background session,
/// `URLSessionSendTransport`); the items 2.1 had queued were moved into the Outbox at first launch
/// (Outbox.migrateLegacy). A transfer iOS was still holding for one of them reports here, under 2.1's
/// session id, and is forwarded to the engine:
///
/// - a finished blob upload (`<itemId>|<mediaUrl>`) → the message only needs posting now;
/// - a finished post (`send|<itemId>`) → it's delivered.
///
/// If one of these lands after the engine already re-sent the message itself, nothing doubles: the
/// server dedups by client id. Safe to delete once no 2.1 install can be mid-update (2.3+).
final class BackgroundUploadService: NSObject {
    static let shared = BackgroundUploadService()

    static let sessionIdentifier = "com.markleit.oldmansbookclub.mediaupload"

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var backgroundCompletionHandler: (() -> Void)?
    private var responseBuffers: [Int: Data] = [:]   // only touched on the session's delegate queue

    private override init() { super.init() }

    /// Recreate 2.1's session at launch so anything it still holds reports in.
    func activate() { _ = session }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
        guard identifier == Self.sessionIdentifier else { return }
        backgroundCompletionHandler = handler
        activate()
    }
}

extension BackgroundUploadService: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseBuffers[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = responseBuffers.removeValue(forKey: task.taskIdentifier)
        guard let desc = task.taskDescription else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        guard error == nil, (200..<300).contains(status) else {
            SendLog.note("legacy transfer failed", nil, "status=\(status)")
            return   // the engine re-sends the migrated item itself
        }
        if desc.hasPrefix("send|"), let id = UUID(uuidString: String(desc.dropFirst("send|".count))),
           let message = SendEngine.decode(body) {
            Task { @MainActor in SendEngine.shared.confirm(clientId: id, message: message) }
        } else {
            let parts = desc.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = UUID(uuidString: parts[0]) else { return }
            Task { @MainActor in SendEngine.shared.legacyBlobUploaded(id, mediaUrl: parts[1]) }
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
