import SwiftUI
import UIKit
import CryptoKit

// MARK: - Shared image cache (two-tier)

// L1: NSCache in memory — fast, evicted on memory pressure.
// L2: JPEG files on disk in Caches/Images/ — survive backgrounding, memory pressure,
//     and app kills. Capped at ~100 MB with LRU eviction by file mtime.
//
// Reads: L1 hit returns immediately. Miss → check L2 on a background queue, repopulate
// L1, return. Writes go to both tiers (L1 sync, L2 async on background queue).
//
// Cache key strategy:
//   - For Azure Blob URLs we own, key on URL path only (drop SAS query) so the same
//     blob is found across SAS rotations.
//   - For everything else, key on full URL (Google Books encodes the book ID in the
//     query — stripping it would collapse all covers onto one slot).
final class ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let diskQueue = DispatchQueue(label: "ImageCache.disk", qos: .utility)
    private let diskDir: URL
    private let maxDiskBytes: Int64 = 100 * 1024 * 1024  // 100 MB

    private init() {
        memory.countLimit = 200
        memory.totalCostLimit = 64 * 1024 * 1024  // 64 MB
        diskDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    private static func bytes(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }

    private func key(for url: URL) -> String {
        guard url.host == "oldmansbookclubstore.blob.core.windows.net" else {
            return url.absoluteString
        }
        // Strip the SAS query (it rotates on every server fetch, so keying by it
        // would defeat the cache). KEEP the fragment — the server uses it as a
        // versioning hint (e.g. avatar URLs gain `#v=<timestamp>` on upload, so
        // a replaced avatar produces a different cache key from the old one).
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }

    private func diskPath(forKey k: String) -> URL {
        let digest = SHA256.hash(data: Data(k.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent("\(name).jpg")
    }

    // L1-only synchronous read — fast path, used when callers can re-check L2 on miss.
    subscript(url: URL) -> UIImage? {
        get { memory.object(forKey: key(for: url) as NSString) }
        set {
            let k = key(for: url)
            if let img = newValue {
                memory.setObject(img, forKey: k as NSString, cost: Self.bytes(img))
                writeToDisk(img, key: k)
            } else {
                memory.removeObject(forKey: k as NSString)
            }
        }
    }

    // L1 + L2 read. Returns immediately on memory hit; otherwise hops to the disk
    // queue, loads + decodes, repopulates memory, and returns.
    func get(_ url: URL) async -> UIImage? {
        if let hit = self[url] { return hit }
        let k = key(for: url)
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            diskQueue.async {
                let path = self.diskPath(forKey: k)
                guard FileManager.default.fileExists(atPath: path.path),
                      let data = try? Data(contentsOf: path),
                      let image = UIImage(data: data) else {
                    cont.resume(returning: nil)
                    return
                }
                // Touch mtime so LRU eviction treats this as recently used
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: path.path
                )
                self.memory.setObject(image, forKey: k as NSString, cost: Self.bytes(image))
                cont.resume(returning: image)
            }
        }
    }

    private func writeToDisk(_ image: UIImage, key: String) {
        diskQueue.async {
            guard let data = image.jpegData(compressionQuality: 0.85) else { return }
            try? data.write(to: self.diskPath(forKey: key), options: .atomic)
            self.enforceCapacityIfNeeded()
        }
    }

    // LRU eviction by file mtime. Cheap heuristic — run after every write.
    // Bounded by maxDiskBytes; deletes oldest until back under cap.
    private func enforceCapacityIfNeeded() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: diskDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }
        struct Meta { let url: URL; let mtime: Date; let size: Int64 }
        let metas: [Meta] = files.compactMap {
            guard let attrs = try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = attrs.fileSize,
                  let mtime = attrs.contentModificationDate else { return nil }
            return Meta(url: $0, mtime: mtime, size: Int64(size))
        }
        var total: Int64 = metas.reduce(0) { $0 + $1.size }
        guard total > maxDiskBytes else { return }
        for m in metas.sorted(by: { $0.mtime < $1.mtime }) {
            guard total > maxDiskBytes else { break }
            try? FileManager.default.removeItem(at: m.url)
            total -= m.size
        }
    }
}

// MARK: - Phase-based cached image (drop-in for AsyncImage)

enum CachedImagePhase {
    case empty, failure
    case success(Image)

    var image: Image? { if case .success(let img) = self { return img }; return nil }
    var isError: Bool { if case .failure = self { return true }; return false }
}

struct CachedRemoteImage<Content: View>: View {
    let url: URL
    @ViewBuilder let content: (CachedImagePhase) -> Content

    @State private var phase: CachedImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    private func load() async {
        if let cached = await ImageCache.shared.get(url) {
            phase = .success(Image(uiImage: cached))
            return
        }
        phase = .empty
        // Retry with backoff on transient failure — Azure Blob can take a moment to
        // become readable after the SAS is broadcast.
        let delaysMs: [UInt64] = [0, 500, 1500, 3500]
        for delay in delaysMs {
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(Int(delay)))
                if Task.isCancelled { return }
            }
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                continue
            }
            let uiImage = await Task.detached(priority: .userInitiated) {
                UIImage(data: data)
            }.value
            guard let uiImage else { continue }
            ImageCache.shared[url] = uiImage
            phase = .success(Image(uiImage: uiImage))
            return
        }
        phase = .failure
    }
}

// MARK: - Book cover (uses same cache)

struct CachedBookCover: View {
    let urlString: String?
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    var refreshToken: UUID = UUID()

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.gray.opacity(0.3))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: refreshToken) { await load() }
    }

    private func load() async {
        guard let urlString, let url = URL(string: urlString) else { return }
        if let cached = await ImageCache.shared.get(url) { image = cached; return }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return }
        let loaded = UIImage(data: data)
        if let loaded { ImageCache.shared[url] = loaded }
        image = loaded
    }
}
