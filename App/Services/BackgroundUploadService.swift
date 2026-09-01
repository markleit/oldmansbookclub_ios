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

    // Accumulates a send task's response body across possibly-multiple didReceive calls,
    // keyed by taskIdentifier. Only touched from delegate callbacks, which the session's
    // serial delegate queue (delegateQueue: nil above) already guarantees run one at a time.
    private var responseBuffers: [Int: Data] = [:]

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
        let prefix = "\(itemId.uuidString)|"
        let tasks: [URLSessionTask] = await withCheckedContinuation { cont in
            session.getAllTasks { cont.resume(returning: $0) }
        }
        return tasks.contains {
            ($0.taskDescription?.hasPrefix(prefix) ?? false) && ($0.state == .running || $0.state == .suspended)
        }
    }

    // MARK: - Message send (post-upload)

    private static let sendTaskPrefix = "send|"

    // JSON codec matching APIClient's own (snake_case keys, ISO8601 w/ fractional seconds) —
    // duplicated rather than shared because this runs from a URLSessionDelegate callback, not
    // through APIClient's normal async call path, so it can't reach APIClient's private encoder.
    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        d.dateDecodingStrategy = .custom { decoder in
            let str = try decoder.singleValueContainer().decode(String.self)
            if let date = iso.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(), debugDescription: "Cannot decode date: \(str)")
        }
        return d
    }()

    /// Posts the "create this message" call over the same background URLSession as the blob
    /// PUT, instead of a SignalR invoke — so a send that outlives the foreground
    /// BackgroundTaskBox window (a big/slow upload, a bad connection) still lands: the OS
    /// carries this HTTP POST independent of app suspension, the same as the upload bytes
    /// themselves (#131). Completion (success + the confirmed Message, or failure) arrives via
    /// `.mediaSendCompleted`, same pattern as `.mediaUploadCompleted`.
    func sendMessage(itemId: UUID, bookId: UUID, type: MessageType, mediaUrl: String,
                      durationSeconds: Int?, clientId: UUID, parentMessageId: UUID?) {
        guard let token = TokenStore.shared.token else { return }
        var request = URLRequest(url: URL(string: "\(ServerEnvironment.baseURLString)/books/\(bookId)/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let payload = APIClient.SendMessagePayload(
            type: type.rawValue, body: nil, mediaUrl: mediaUrl, durationSeconds: durationSeconds,
            clientId: clientId, parentMessageId: parentMessageId, deviceId: TokenStore.shared.registeredDeviceToken)
        guard let bodyData = try? Self.jsonEncoder.encode(payload) else { return }
        let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent("send-\(itemId.uuidString).json")
        do { try bodyData.write(to: tempUrl) } catch { return }
        let task = session.uploadTask(with: request, fromFile: tempUrl)
        task.taskDescription = "\(Self.sendTaskPrefix)\(itemId.uuidString)"
        task.resume()
    }

    /// Whether a background send for this item is already running/queued (mirrors
    /// `hasInflightUpload`) — guards a re-entrant sendMediaItem from kicking a second POST.
    func hasInflightSend(itemId: UUID) async -> Bool {
        let prefix = "\(Self.sendTaskPrefix)\(itemId.uuidString)"
        let tasks: [URLSessionTask] = await withCheckedContinuation { cont in
            session.getAllTasks { cont.resume(returning: $0) }
        }
        return tasks.contains {
            $0.taskDescription == prefix && ($0.state == .running || $0.state == .suspended)
        }
    }

    private func handleSendCompletion(task: URLSessionTask, error: Error?) {
        defer { responseBuffers[task.taskIdentifier] = nil }
        guard let desc = task.taskDescription,
              let itemId = UUID(uuidString: String(desc.dropFirst(Self.sendTaskPrefix.count))) else { return }

        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        let data = responseBuffers[task.taskIdentifier]

        guard error == nil, (200..<300).contains(status), let data,
              let message = try? Self.jsonDecoder.decode(Message.self, from: data) else {
            // A 4xx carries a real reason (rate limit, validation) the same way the hub's
            // HubException did — surface it if present so the UI isn't just "failed".
            let serverMessage = data.flatMap { try? Self.jsonDecoder.decode(SendErrorBody.self, from: $0) }?.error
            Task { @MainActor in
                NotificationCenter.default.post(name: .mediaSendCompleted, object: nil, userInfo: [
                    "itemId": itemId, "success": false,
                    "errorMessage": serverMessage as Any
                ])
            }
            return
        }
        Task { @MainActor in
            NotificationCenter.default.post(name: .mediaSendCompleted, object: nil, userInfo: [
                "itemId": itemId, "success": true, "message": message
            ])
        }
    }

    private struct SendErrorBody: Decodable { let error: String }
}

extension BackgroundUploadService: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask.taskDescription?.hasPrefix(Self.sendTaskPrefix) == true else { return }
        responseBuffers[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let desc = task.taskDescription else { return }
        if desc.hasPrefix(Self.sendTaskPrefix) {
            handleSendCompletion(task: task, error: error)
            return
        }

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
    /// `itemId: UUID` and `success: Bool`. The active BookViewModel flushes to drive the send.
    static let mediaUploadCompleted = Notification.Name("MediaUploadCompleted")

    /// Posted (main thread) when a background message-send POST finishes; userInfo carries
    /// `itemId: UUID`, `success: Bool`, and on success `message: Message` (the server's
    /// confirmed MessageDto — used to reconcile the bubble directly, no echo wait needed) or
    /// on failure an optional `errorMessage: String`.
    static let mediaSendCompleted = Notification.Name("MediaSendCompleted")
}
