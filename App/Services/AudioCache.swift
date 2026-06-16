import Foundation
import CryptoKit

// Disk cache for voice-message audio so playback starts instantly instead of streaming
// the blob over the network on every tap. Files live in Caches/Audio/ (iOS purges under
// disk pressure; not iCloud-backed; re-fetchable from the server). Keyed by blob path
// (SAS query stripped) so a re-issued read SAS still hits the cache. Bounded by a hard
// LRU size cap — never grows unbounded.
//
// @unchecked Sendable: all mutable state is the file system plus an NSLock-guarded
// in-flight set, so it's safe to share across the prefetch tasks.
final class AudioCache: @unchecked Sendable {
    static let shared = AudioCache()

    private let dir: URL
    private let maxBytes: Int64 = 150 * 1024 * 1024   // 150 MB LRU cap
    private let lock = NSLock()
    private var inFlight = Set<String>()

    private init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func key(for url: URL) -> String {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.query = nil   // drop SAS so a rotated read SAS still maps to the same blob
        let base = comps?.url?.absoluteString ?? url.absoluteString
        let digest = SHA256.hash(data: Data(base.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func filePath(for url: URL) -> URL {
        dir.appendingPathComponent(key(for: url)).appendingPathExtension("m4a")
    }

    // Local file for an already-cached blob (and touch its mtime for LRU). Synchronous
    // and fast — just a file-exists check — so the player can branch on it inline.
    func cachedFileURL(for url: URL) -> URL? {
        let path = filePath(for: url)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
        return path
    }

    // Fire-and-forget download into the cache. No-ops if already cached, in flight, or a
    // local file:// URL (optimistic just-recorded sends play from disk already).
    func prefetch(_ url: URL) {
        guard url.scheme == "https" else { return }
        let path = filePath(for: url)
        if FileManager.default.fileExists(atPath: path.path) { return }
        let k = key(for: url)
        lock.lock()
        if inFlight.contains(k) { lock.unlock(); return }
        inFlight.insert(k)
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.clearInFlight(k) }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  !data.isEmpty else { return }
            try? data.write(to: path, options: .atomic)
            self.enforceCapacity()
        }
    }

    private func clearInFlight(_ k: String) {
        lock.lock(); defer { lock.unlock() }
        inFlight.remove(k)
    }

    // LRU eviction by file mtime (last access) once over the cap.
    private func enforceCapacity() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }
        struct Meta { let url: URL; let mtime: Date; let size: Int64 }
        let metas: [Meta] = files.compactMap {
            guard let a = try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = a.fileSize, let mtime = a.contentModificationDate else { return nil }
            return Meta(url: $0, mtime: mtime, size: Int64(size))
        }
        var total = metas.reduce(Int64(0)) { $0 + $1.size }
        guard total > maxBytes else { return }
        for m in metas.sorted(by: { $0.mtime < $1.mtime }) {
            guard total > maxBytes else { break }
            try? FileManager.default.removeItem(at: m.url)
            total -= m.size
        }
    }
}
