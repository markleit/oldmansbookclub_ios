import Foundation

// #204 — how a send reaches the server. Two routes, used together:
//
// - BACKGROUND: iOS's background transfer (nsurlsessiond). Handed over at tap time, while the app
//   is in the foreground, so iOS treats it as user-initiated rather than "discretionary"; from then
//   on iOS carries it — locked phone, app suspended or killed by the system — waits for a network,
//   and relaunches the app to report the result. The one thing it can't survive is a force-quit.
// - DIRECT: an ordinary request while the app is open. nsurlsessiond schedules on its own clock
//   (#207 saw one held 86 s with the app open), so text also goes directly at once, and voice/photo
//   directly if the background copy hasn't landed after a few seconds. Whichever lands first wins;
//   the server dedups by client_id, and the engine cancels the other copy.

/// Identifies one background task across app relaunches (it rides in `taskDescription`).
struct SendTaskKey: Hashable {
    let itemId: UUID
    let attempt: Int
    let step: SendRequestBuilder.Step

    private static let prefix = "ombc2"

    var taskDescription: String {
        switch step {
        case .post: return "\(Self.prefix)|\(itemId.uuidString)|\(attempt)|post"
        case .blobUpload(let mediaUrl): return "\(Self.prefix)|\(itemId.uuidString)|\(attempt)|blob|\(mediaUrl)"
        }
    }

    init(itemId: UUID, attempt: Int, step: SendRequestBuilder.Step) {
        self.itemId = itemId
        self.attempt = attempt
        self.step = step
    }

    init?(taskDescription: String) {
        let parts = taskDescription.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4, parts[0] == Self.prefix,
              let id = UUID(uuidString: parts[1]), let attempt = Int(parts[2]) else { return nil }
        switch parts[3] {
        case "post": self.init(itemId: id, attempt: attempt, step: .post)
        case "blob" where parts.count == 5: self.init(itemId: id, attempt: attempt, step: .blobUpload(mediaUrl: parts[4]))
        default: return nil
        }
    }
}

/// What came back: a status and body, or a transport error.
struct SendResponse {
    var status: Int?
    var body: Data?
    var error: Error?
    var retryAfter: String?

    var verdict: SendVerdict {
        SendPolicy.verdict(status: status, error: error, body: body, retryAfter: retryAfter)
    }
}

@MainActor
protocol SendTransport: AnyObject {
    /// Results of background tasks — including ones started by a previous run of the app.
    var onBackgroundResult: ((SendTaskKey, SendResponse) -> Void)? { get set }
    /// `notBefore`: iOS holds the transfer until then — the retry clock, kept while the app is
    /// suspended and can't run it.
    func submitBackground(_ key: SendTaskKey, request: URLRequest, bodyFile: URL, notBefore: Date?)
    func sendDirect(_ request: URLRequest, body: Data?, bodyFile: URL?) async -> SendResponse
    func cancelBackground(itemId: UUID)
    /// Background tasks iOS still holds (running or waiting for a network).
    func backgroundTaskKeys() async -> [SendTaskKey]
    func cancelAll()
}

/// The real transport: one background URLSession for every send.
@MainActor
final class URLSessionSendTransport: NSObject, SendTransport {
    static let sessionIdentifier = "com.markleit.oldmansbookclub.send"

    var onBackgroundResult: ((SendTaskKey, SendResponse) -> Void)? {
        didSet {
            // Results that arrived before anyone was listening (iOS can relaunch the app straight
            // into its background events, ahead of the engine starting).
            guard let onBackgroundResult else { return }
            let early = earlyResults
            earlyResults = []
            early.forEach { onBackgroundResult($0.0, $0.1) }
        }
    }
    private var earlyResults: [(SendTaskKey, SendResponse)] = []
    /// iOS's "done with this wake" handlers, per background session.
    private var systemCompletionHandlers: [String: () -> Void] = [:]
    /// One delegate per session: task numbers are only unique within a session.
    private let delegate = Delegate()
    private let shareDelegate = Delegate()
    private var shareJoined = false

    private lazy var background: URLSession = makeSession(Self.sessionIdentifier, delegate: delegate, shared: false)

    /// The share sheet's uploads (PR 10). The extension started them in its own session; the app
    /// joins it to hear their results (iOS relaunches the app for them). Joined only at launch or
    /// for that wake — one process at a time can hold a background session.
    private lazy var share: URLSession = {
        shareJoined = true
        return makeSession(ShareInbox.sessionIdentifier, delegate: shareDelegate, shared: true)
    }()

    private func makeSession(_ identifier: String, delegate: Delegate, shared: Bool) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false          // a chat message, not a podcast download
        config.sessionSendsLaunchEvents = true  // relaunch the app to report a result
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 60
        if shared { config.sharedContainerIdentifier = SharedContainer.appGroupId }
        delegate.deliver = { [weak self] key, response in
            Task { @MainActor in
                guard let self else { return }
                if let handler = self.onBackgroundResult { handler(key, response) } else { self.earlyResults.append((key, response)) }
            }
        }
        delegate.finishedEvents = { [weak self] in
            Task { @MainActor in self?.systemCompletionHandlers.removeValue(forKey: identifier)?() }
        }
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// The sessions with tasks this app should know about.
    private var joinedSessions: [URLSession] { shareJoined ? [background, share] : [background] }

    private let direct: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = false   // offline is handled by the engine, not by parking here
        return URLSession(configuration: config)
    }()

    /// Recreate the session at launch so finished background tasks deliver their results.
    func activate() { _ = background }

    func setSystemCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
        switch identifier {
        case Self.sessionIdentifier:
            systemCompletionHandlers[identifier] = handler
            activate()
        case ShareInbox.sessionIdentifier:
            systemCompletionHandlers[identifier] = handler
            _ = share
        default:
            return
        }
    }

    func submitBackground(_ key: SendTaskKey, request: URLRequest, bodyFile: URL, notBefore: Date?) {
        let task = background.uploadTask(with: request, fromFile: bodyFile)
        task.taskDescription = key.taskDescription
        if let notBefore { task.earliestBeginDate = notBefore }
        task.resume()
    }

    func sendDirect(_ request: URLRequest, body: Data?, bodyFile: URL?) async -> SendResponse {
        // If the app is backgrounded mid-request, finish it in iOS's grace period rather than
        // abandoning it (the background copy carries it either way).
        let grace = BackgroundTaskBox(name: "send-direct")
        defer { grace.end() }
        do {
            let (data, response): (Data, URLResponse)
            if let bodyFile {
                (data, response) = try await direct.upload(for: request, fromFile: bodyFile)
            } else {
                (data, response) = try await direct.upload(for: request, from: body ?? Data())
            }
            let http = response as? HTTPURLResponse
            return SendResponse(status: http?.statusCode, body: data, error: nil,
                                retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
        } catch {
            return SendResponse(status: nil, body: nil, error: error, retryAfter: nil)
        }
    }

    func cancelBackground(itemId: UUID) {
        for session in joinedSessions {
            session.getAllTasks { tasks in
                for task in tasks where task.taskDescription.flatMap(SendTaskKey.init(taskDescription:))?.itemId == itemId {
                    task.cancel()
                }
            }
        }
    }

    func backgroundTaskKeys() async -> [SendTaskKey] {
        // At launch: the share sheet's uploads count too (PR 10).
        if SharedContainer.appGroupId != nil { _ = share }
        var tasks: [URLSessionTask] = []
        for session in joinedSessions {
            tasks += await withCheckedContinuation { cont in session.getAllTasks { cont.resume(returning: $0) } }
        }
        return tasks
            .filter { $0.state == .running || $0.state == .suspended }
            .compactMap { $0.taskDescription.flatMap(SendTaskKey.init(taskDescription:)) }
    }

    func cancelAll() {
        for session in joinedSessions { session.getAllTasks { $0.forEach { $0.cancel() } } }
    }

    /// The session delegate — called on the session's own serial queue.
    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        var deliver: ((SendTaskKey, SendResponse) -> Void)?
        var finishedEvents: (() -> Void)?
        private var buffers: [Int: Data] = [:]

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            buffers[dataTask.taskIdentifier, default: Data()].append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let body = buffers.removeValue(forKey: task.taskIdentifier)
            guard let key = task.taskDescription.flatMap(SendTaskKey.init(taskDescription:)) else { return }
            let http = task.response as? HTTPURLResponse
            deliver?(key, SendResponse(status: http?.statusCode, body: body, error: error,
                                       retryAfter: http?.value(forHTTPHeaderField: "Retry-After")))
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            finishedEvents?()
        }
    }
}
