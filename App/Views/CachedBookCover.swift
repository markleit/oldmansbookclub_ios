import SwiftUI
import UIKit

// MARK: - Shared image cache

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024  // 64 MB
    }

    private static func bytes(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }

    // For Azure Blob URLs, strip the query — SAS tokens are regenerated server-side
    // on every fetch, so the full URL changes constantly even when the blob is
    // identical. Keying by path means re-entering a chat finds the cached image.
    // For other hosts (e.g. Google Books, which encodes the book ID in the query)
    // we keep the full URL — stripping the query would collapse every book onto
    // the same cache slot and show the first cover everywhere.
    private func key(for url: URL) -> NSString {
        guard url.host == "oldmansbookclubstore.blob.core.windows.net" else {
            return url.absoluteString as NSString
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return (components?.url?.absoluteString ?? url.absoluteString) as NSString
    }

    subscript(url: URL) -> UIImage? {
        get { cache.object(forKey: key(for: url)) }
        set {
            let k = key(for: url)
            if let img = newValue { cache.setObject(img, forKey: k, cost: Self.bytes(img)) }
            else { cache.removeObject(forKey: k) }
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
        if let cached = ImageCache.shared[url] {
            phase = .success(Image(uiImage: cached))
            return
        }
        phase = .empty
        // Retry once on transient failure — Azure Blob has a brief eventual-consistency
        // window where a GET immediately after PUT can 404, which surfaces as a "preview
        // missing" bubble until the user re-enters the chat. One retry covers that.
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(750))
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
        if let cached = ImageCache.shared[url] { image = cached; return }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return }
        let loaded = UIImage(data: data)
        if let loaded { ImageCache.shared[url] = loaded }
        image = loaded
    }
}
