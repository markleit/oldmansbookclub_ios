import Foundation
import UIKit

// Remembers each photo's aspect ratio (width / height), keyed by URL (#122).
//
// A chat bubble has to choose its size before the image has decoded. Without a remembered
// ratio every photo would start as a placeholder of some arbitrary shape and then resize as it
// loads — and in a bottom-anchored chat that means bubbles jumping and the scroll position
// moving under the reader. Caching the ratio means only the very first sighting of a photo can
// shift; every later render of it is stable, including across launches.
//
// Ratios are tiny and derived — losing the file costs one re-measure, nothing more.
@MainActor
final class ImageAspectStore: ObservableObject {
    static let shared = ImageAspectStore()

    // Sane bounds. A ratio outside these is a panorama or a column strip; clamping keeps one
    // odd photo from producing a bubble the width of a hair or the height of the screen.
    // The lower bound is set below a phone screenshot (~0.46) deliberately: screenshots of book
    // pages are common here, and a cropped page of text is precisely the case where you can't
    // tell what you're looking at. At 0.6 a screenshot still lost ~23% of its height.
    static let minAspect: CGFloat = 0.45     // tall portrait — phone screenshots land ~0.46
    static let maxAspect: CGFloat = 1.9      // wide landscape
    // Used until the real ratio is known — close to a typical phone photo, so the first load
    // settles rather than snapping.
    static let placeholder: CGFloat = 3.0 / 4.0

    private let key = "photoAspectRatios"
    @Published private(set) var ratios: [String: CGFloat]

    private init() {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        ratios = raw.mapValues { CGFloat($0) }
    }

    func aspect(for url: URL) -> CGFloat? { ratios[Self.cacheKey(url)] }

    func record(_ image: UIImage, for url: URL) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let ratio = min(max(size.width / size.height, Self.minAspect), Self.maxAspect)
        let key = Self.cacheKey(url)
        guard ratios[key] != ratio else { return }
        ratios[key] = ratio
        UserDefaults.standard.set(ratios.mapValues { Double($0) }, forKey: self.key)
    }

    // Media URLs carry a SAS token that is re-issued on every load, so the full URL is not a
    // stable identity — the path alone is.
    private static func cacheKey(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.query = nil
        return c?.url?.absoluteString ?? url.absoluteString
    }
}
