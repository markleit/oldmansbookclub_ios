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
            token: { await APIClient.shared.sendToken() },
            // The stored token is the one the server just refused: renew unless it has changed.
            tokenAfterRejection: {
                await APIClient.shared.sendToken(afterRejecting: TokenStore.shared.sendToken ?? TokenStore.shared.token ?? "")
            },
            compressVideo: { await VideoCompressor.compress($0) },
            fetchSlots: { await APIClient.shared.videoSlots(clubId: $0, count: $1) },
            slotClubs: { TokenStore.shared.clubId.map { [$0] } ?? [] },
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
            },
            reminder: { SendReminder.apply($0) })
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
        // Leaving the foreground: every unsent message already has its carrier with iOS; the app is
        // kept awake (iOS's ~30 s) only for a carrier still being built — a token being renewed, a
        // video with no slot reserving.
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                let grace = BackgroundTaskBox(name: "send-hand-over")
                SendEngine.shared.appWillResignActive { grace.end() }
            }
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
