import UIKit
import ImageIO
import UniformTypeIdentifiers

// #178 — what the host app handed us, reduced to what OMBC can send. Video is intentionally
// not accepted yet (the activation rule excludes it): transcoding inside an extension's ~120 MB
// memory limit is too risky, so it's a later phase.
enum SharedItem: Identifiable {
    case photo(id: UUID, jpeg: Data, thumbnail: UIImage)
    case link(id: UUID, URL)
    case text(id: UUID, String)

    var id: UUID {
        switch self {
        case .photo(let id, _, _), .link(let id, _), .text(let id, _): return id
        }
    }
}

enum SharedItemLoader {
    /// Photos first, in the order shared; then at most one link, else plain text. Safari offers
    /// both a URL and its title as text — the URL wins, the title is dropped.
    static func load(from context: NSExtensionContext?) async -> [SharedItem] {
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var photos: [SharedItem] = []
        var link: SharedItem?
        var text: SharedItem?
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let photo = await loadPhoto(provider) { photos.append(photo) }
            } else if link == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = await loadURL(provider), !url.isFileURL {
                link = .link(id: UUID(), url)
            } else if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let s = await loadText(provider), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = .text(id: UUID(), s)
            }
        }
        return photos + [link ?? text].compactMap { $0 }
    }

    // The host can hand an image over as a file URL (Photos), raw Data, or a UIImage (the
    // screenshot editor) — handle all three, and never decode a full-resolution bitmap: a 48 MP
    // photo is ~190 MB decoded, over the extension's whole memory budget.
    private static func loadPhoto(_ provider: NSItemProvider) async -> SharedItem? {
        let item = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier)
        let source: CGImageSource?
        switch item {
        case let url as URL: source = CGImageSourceCreateWithURL(url as CFURL, nil)
        case let data as Data: source = CGImageSourceCreateWithData(data as CFData, nil)
        case let image as UIImage:
            source = image.jpegData(compressionQuality: 0.9).flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
        default: source = nil
        }
        guard let source else { return nil }
        // Same output as the in-app picker: UIImage.resizedForUpload(maxDimension: 1024) is in
        // points, i.e. 1024 × screen scale pixels, then JPEG 0.7 (BookViewModel.sendPhoto).
        let maxPixels = 1024 * UIScreen.main.scale
        guard let upload = downsample(source, maxPixels: maxPixels),
              let jpeg = UIImage(cgImage: upload).jpegData(compressionQuality: 0.7),
              let thumb = downsample(source, maxPixels: 240) else { return nil }
        return .photo(id: UUID(), jpeg: jpeg, thumbnail: UIImage(cgImage: thumb))
    }

    private static func downsample(_ source: CGImageSource, maxPixels: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honor EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
        return (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
        return (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }
}
