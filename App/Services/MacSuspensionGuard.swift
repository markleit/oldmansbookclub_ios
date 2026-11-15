import Foundation
import UIKit

// #273 / #274 / #279 — "RUNNINGBOARD 0xdead10cc" kills of the iPhone app running on a Mac
// ("Designed for iPhone"), right after it was hidden.
//
// Cause, proven 2026-11-15 on the Mac that filed all three: once Metal has compiled shaders for
// the app, it keeps exclusive flock()s on its shader-cache files in the app's system cache folder
// (/var/folders/…/C/<bundle id>/…/com.apple.metal*/). On a Mac, RunningBoard suspends a hidden
// iPhone app ~5 s after it leaves the foreground, then looks at every file the app holds a lock
// on: one outside the app's home or temp folder counts as "a shared file lock" and the app is
// killed with 0xdead10cc. Short sessions hadn't built the cache yet and always survived (one
// process: 13 suspensions); the 7-hour and 19-hour sessions died on their first one.
//
// The locks are Metal's, not ours, so we can't release them. RunningBoard skips any file carrying
// the `com.apple.runningboard.can-suspend-locked` attribute, so the app tags Metal's cache files
// every time it leaves the foreground. Verified on the live App Store app: with the tag it was
// suspended and survived; with the tag removed the same process was killed 0.1 s after suspension.
//
// iPhone/iPad don't need this: there Metal's cache lives inside the app's own container, which
// RunningBoard allows.
enum MacSuspensionGuard {
    static let attribute = "com.apple.runningboard.can-suspend-locked"

    @MainActor private static var observers: [NSObjectProtocol] = []

    /// Call once at launch. Does nothing unless this is the iPhone app running on a Mac.
    @MainActor
    static func start() {
        guard ProcessInfo.processInfo.isiOSAppOnMac, observers.isEmpty else { return }
        guard let directory = systemCacheDirectory() else {
            Breadcrumbs.record("mac lock guard: no cache folder")
            return
        }
        tag(directory)
        // Synchronous on purpose: a handful of files, and it must be done before the suspension
        // that follows a few seconds later.
        observers = [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { _ in
                tag(directory)
            }
        }
    }

    /// In the crash trail, so a Mac report from a build with this fix shows whether it ran.
    @MainActor private static func tag(_ directory: URL) {
        let count = tagMetalCaches(in: directory)
        if count > 0 { Breadcrumbs.record("mac lock guard: tagged \(count)") }
    }

    /// The per-app system cache folder (DARWIN_USER_CACHE_DIR), where Metal keeps its shader cache:
    /// what libc says, else worked out from where macOS put the app (see `cacheDirectory(forBundleAt:)`).
    static func systemCacheDirectory() -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 {
            let path = String(cString: buffer)
            if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        guard let bundleId = Bundle.main.bundleIdentifier,
              let derived = cacheDirectory(forBundleAt: Bundle.main.bundleURL, bundleId: bundleId),
              FileManager.default.fileExists(atPath: derived.path) else { return nil }
        return derived
    }

    /// macOS runs an iPhone app from /var/folders/<a>/<b>/X/<uuid>/d/Wrapper/<App>.app and gives it
    /// the cache folder /var/folders/<a>/<b>/C/<bundle id> (seen on the reporting Mac).
    static func cacheDirectory(forBundleAt bundleURL: URL, bundleId: String) -> URL? {
        let parts = bundleURL.standardizedFileURL.pathComponents
        guard let folders = parts.firstIndex(of: "folders"), folders + 3 < parts.count,
              parts[folders + 3] == "X" else { return nil }
        let base = NSString.path(withComponents: Array(parts[...(folders + 2)]))
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("C", isDirectory: true)
            .appendingPathComponent(bundleId, isDirectory: true)
    }

    /// Tags every file below a `com.apple.metal…` folder inside `directory` that isn't tagged yet.
    /// Returns how many it tagged.
    @discardableResult
    static func tagMetalCaches(in directory: URL) -> Int {
        let base = directory.standardizedFileURL.pathComponents.count
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        else { return 0 }
        var tagged = 0
        for case let url as URL in walker {
            let below = url.standardizedFileURL.pathComponents.dropFirst(base)
            guard below.dropLast().contains(where: { $0.hasPrefix("com.apple.metal") }),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  !isTagged(url) else { continue }
            if setxattr(url.path, attribute, "1", 1, 0, 0) == 0 { tagged += 1 }
        }
        return tagged
    }

    static func isTagged(_ url: URL) -> Bool {
        getxattr(url.path, attribute, nil, 0, 0, 0) >= 0
    }
}
