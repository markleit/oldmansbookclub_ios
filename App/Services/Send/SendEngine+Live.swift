import UIKit

// #204 — the engine wired to the real world: iOS's background transfer, the network monitor,
// the API's tokens, the chat cache. Everything SendEngine needs comes in through SendEnvironment,
// so the engine itself is unit-tested with fakes (SendEngineTests).
extension SendEngine {
    /// The transport, separate from `shared` so the AppDelegate can hand it iOS's background
    /// events (and a UI test can cancel leftover transfers) without starting the engine.
    static let liveTransport = URLSessionSendTransport()

    static let shared: SendEngine = {
        let env = SendEnvironment(
            isAppActive: { UIApplication.shared.applicationState == .active },
            hasNetwork: { NetworkReachability.shared.hasNetworkPath },
            baseURL: { ServerEnvironment.baseURL },
            deviceId: { TokenStore.shared.registeredDeviceToken },
            myUserId: { TokenStore.shared.userId },
            token: { await APIClient.shared.sendToken(validFor: $0) },
            // The stored token is the one the server just refused: refresh unless it has changed.
            tokenAfterRejection: { await APIClient.shared.sendToken(afterRejecting: TokenStore.shared.token ?? "") },
            uploadLink: { clubId, ext in
                let link = try await APIClient.shared.getUploadUrl(clubId: clubId, ext: ext)
                guard let url = URL(string: link.uploadUrl) else { throw URLError(.badURL) }
                return (url, link.mediaUrl)
            },
            schedule: { delay, action in
                let task = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    action()
                }
                return { task.cancel() }
            },
            cacheConfirmed: { bookId, message in
                let merged = ChatCache.merge(existing: ChatCache.load(bookId: bookId), incoming: [message],
                                             myUserId: TokenStore.shared.userId)
                ChatCache.save(merged.messages, bookId: bookId, excludingPending: [])
            })
        return SendEngine(outbox: Outbox(), transport: liveTransport, environment: env)
    }()

    /// Wire the engine to the app's triggers and start it. Once, from didFinishLaunching — which
    /// also runs when iOS launches the app in the background to report a finished transfer.
    static func startLive() {
        NetworkReachability.shared.onBecameReachable {
            Task { @MainActor in SendEngine.shared.networkBecameReachable() }
        }
        NetworkReachability.shared.onBecameUnreachable {
            Task { @MainActor in SendEngine.shared.networkLost() }
        }
        NotificationCenter.default.addObserver(forName: .apiServerReachable, object: nil, queue: .main) { _ in
            Task { @MainActor in SendEngine.shared.serverReachable() }
        }
        Task { @MainActor in await SendEngine.shared.start() }
    }

    #if DEBUG
    /// Hermetic UI tests start from nothing queued (#204 T3): the outbox emptied and any transfer a
    /// previous test left with iOS cancelled. Runs before `shared` is first touched.
    static func resetForUITests() {
        Outbox(directory: Outbox.defaultDirectory()).removeAll()
        liveTransport.cancelAll()
    }
    #endif
}
