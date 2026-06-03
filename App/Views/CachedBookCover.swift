import SwiftUI
import UIKit

// MARK: - Shared image cache

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    private init() { cache.countLimit = 200 }

    subscript(url: URL) -> UIImage? {
        get { cache.object(forKey: url as NSURL) }
        set {
            if let img = newValue { cache.setObject(img, forKey: url as NSURL) }
            else { cache.removeObject(forKey: url as NSURL) }
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
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let uiImage = UIImage(data: data) else {
            phase = .failure
            return
        }
        ImageCache.shared[url] = uiImage
        phase = .success(Image(uiImage: uiImage))
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
