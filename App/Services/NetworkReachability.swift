import Foundation
import Network

// #146 — a shared, coarse "is there any network path at all" signal.
//
// Exists because URLSession's own failure timing is a poor stand-in for it. With no network,
// a request still has to exhaust name resolution and connection attempts before erroring —
// measured on-device at ~20s in airplane mode when the host is an mDNS name like
// `Marks-MacBook.local` (resolution alone takes seconds to give up). Turning off
// `waitsForConnectivity` stops the request being *parked*, but doesn't make that any faster.
//
// Airplane mode, by contrast, is knowable instantly: NWPathMonitor reports the path as
// `.unsatisfied` with no interface. Checking that before attempting a send turns a ~20s hang
// into an immediate, actionable failure.
//
// Deliberately answers ONLY the coarse question. A satisfied path says nothing about whether
// a particular server is up — a stopped dev API on a live Wi-Fi network still has to fail via
// the normal connection timeout, which is correct.
final class NetworkReachability: @unchecked Sendable {
    static let shared = NetworkReachability()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    // Optimistic until the first path update lands, so a send issued in the first moments after
    // launch is never falsely failed before the monitor has reported anything.
    private var status: NWPath.Status = .satisfied

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock()
            status = path.status
            lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "network-reachability"))
    }

    var hasNetworkPath: Bool {
        lock.lock()
        defer { lock.unlock() }
        return status != .unsatisfied
    }
}
