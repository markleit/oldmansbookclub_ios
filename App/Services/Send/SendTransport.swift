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
    /// An upload's progress while the app is running: (bytes sent, bytes in all).
    var onBackgroundProgress: ((SendTaskKey, Int64, Int64) -> Void)? { get set }
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
    var onBackgroundProgress: ((SendTaskKey, Int64, Int64) -> Void)?
    /// iOS's "done with this wake" handlers, per background session.
    private var systemCompletionHandlers: [String: () -> Void] = [:]

    /// Sessions by identifier: the app's own, and the share sheet's ones this run has joined (PR 10) —
    /// joined only when iOS wakes the app for one, since the extension that started it is gone.
    /// Each has its own delegate: task numbers are only unique within a session.
    private var sessions: [String: URLSession] = [:]
    private var delegates: [String: Delegate] = [:]
    /// Work waiting for a session still being created, in the order it came.
    private var waiting: [String: [(URLSession) -> Void]] = [:]

    /// Runs `body` with the session, creating it first if need be — off the main thread (#204 design
    /// v2). On iOS 26.6 and 27, creating a background session can block at launch inside
    /// NSURLBackgroundSession (Apple Developer Forums thread 848396, across many apps), and a long
    /// block on the main thread at launch is a watchdog kill. Work queues until it exists and then
    /// runs in order, so a cancel can't overtake the submit it follows.
    private func withSession(_ identifier: String, _ body: @escaping (URLSession) -> Void) {
        if let session = sessions[identifier] { return body(session) }
        let creating = waiting[identifier] != nil
        waiting[identifier, default: []].append(body)
        guard !creating else { return }
        let delegate = Delegate()
        delegates[identifier] = delegate
        wire(delegate, identifier)
        let shared = identifier != Self.sessionIdentifier
        Task.detached(priority: .userInitiated) { [weak self] in
            let session = Self.makeSession(identifier, delegate: delegate, shared: shared)
            await self?.sessionReady(identifier, session)
        }
    }

    private func sessionReady(_ identifier: String, _ session: URLSession) {
        sessions[identifier] = session
        let queued = waiting.removeValue(forKey: identifier) ?? []
        queued.forEach { $0(session) }
    }

    nonisolated private static func makeSession(_ identifier: String, delegate: Delegate, shared: Bool) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false          // a chat message, not a podcast download
        config.sessionSendsLaunchEvents = true  // relaunch the app to report a result
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 60
        if shared { config.sharedContainerIdentifier = SharedContainer.appGroupId }
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private func wire(_ delegate: Delegate, _ identifier: String) {
        delegate.deliver = { [weak self] key, response in
            Task { @MainActor in
                guard let self else { return }
                if let handler = self.onBackgroundResult { handler(key, response) } else { self.earlyResults.append((key, response)) }
            }
        }
        delegate.progress = { [weak self] key, sent, total in
            Task { @MainActor in self?.onBackgroundProgress?(key, sent, total) }
        }
        delegate.finishedEvents = { [weak self] in
            Task { @MainActor in self?.systemCompletionHandlers.removeValue(forKey: identifier)?() }
        }
    }

    /// Every session with tasks this app should know about: its own (created if need be) and the
    /// share sheet's ones already joined.
    private func forEachSession(_ body: @escaping (URLSession) -> Void) {
        withSession(Self.sessionIdentifier, body)
        for (identifier, session) in sessions where identifier != Self.sessionIdentifier { body(session) }
    }

    private let direct: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = false   // offline is handled by the engine, not by parking here
        return URLSession(configuration: config)
    }()

    /// Recreate the session at launch so finished background tasks deliver their results.
    func activate() { withSession(Self.sessionIdentifier) { _ in } }

    func setSystemCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
        guard identifier == Self.sessionIdentifier || ShareInbox.isShareSession(identifier) else { return }
        systemCompletionHandlers[identifier] = handler
        withSession(identifier) { _ in }
    }

    func submitBackground(_ key: SendTaskKey, request: URLRequest, bodyFile: URL, notBefore: Date?) {
        withSession(Self.sessionIdentifier) { session in
            let task = session.uploadTask(with: request, fromFile: bodyFile)
            task.taskDescription = key.taskDescription
            if let notBefore { task.earliestBeginDate = notBefore }
            task.resume()
        }
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
        forEachSession { session in
            session.getAllTasks { tasks in
                for task in tasks where task.taskDescription.flatMap(SendTaskKey.init(taskDescription:))?.itemId == itemId {
                    task.cancel()
                }
            }
        }
    }

    func backgroundTaskKeys() async -> [SendTaskKey] {
        var tasks: [URLSessionTask] = []
        let identifiers = [Self.sessionIdentifier] + sessions.keys.filter { $0 != Self.sessionIdentifier }
        for identifier in identifiers {
            tasks += await withCheckedContinuation { cont in
                withSession(identifier) { $0.getAllTasks { cont.resume(returning: $0) } }
            }
        }
        return tasks
            .filter { $0.state == .running || $0.state == .suspended }
            .compactMap { $0.taskDescription.flatMap(SendTaskKey.init(taskDescription:)) }
    }

    func cancelAll() {
        forEachSession { $0.getAllTasks { $0.forEach { $0.cancel() } } }
    }

    /// The session delegate — called on the session's own serial queue.
    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        var deliver: ((SendTaskKey, SendResponse) -> Void)?
        var progress: ((SendTaskKey, Int64, Int64) -> Void)?
        var finishedEvents: (() -> Void)?
        private var buffers: [Int: Data] = [:]
        private var lastProgress: [Int: Date] = [:]

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            // At most twice a second: it only feeds a progress bar.
            let now = Date()
            if let last = lastProgress[task.taskIdentifier], now.timeIntervalSince(last) < 0.5 { return }
            lastProgress[task.taskIdentifier] = now
            guard let key = task.taskDescription.flatMap(SendTaskKey.init(taskDescription:)) else { return }
            progress?(key, totalBytesSent, totalBytesExpectedToSend)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            buffers[dataTask.taskIdentifier, default: Data()].append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let body = buffers.removeValue(forKey: task.taskIdentifier)
            lastProgress[task.taskIdentifier] = nil
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
