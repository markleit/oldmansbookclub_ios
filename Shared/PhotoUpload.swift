import UIKit

/// #204 — the size a photo is sent at, from the chat and from the share sheet alike: 2048 pixels on
/// the long side, JPEG 0.7 — about 1 MB, still sharp full-screen.
///
/// It used to be "1024", but in points: on a 3× phone that rendered 3072 px, ~1.7 MB a photo. Ten
/// at once is ~17 MB on one connection, long enough for the photos at the back of the queue to be
/// cut off by the server (2.2 (2) device pass; see API NoMinimumUploadSpeedAttribute).
enum PhotoUpload {
    static let maxPixels: CGFloat = 2048
    static let jpegQuality: CGFloat = 0.7

    /// The bytes the chat sends for a picked photo.
    static func jpeg(_ image: UIImage) -> Data? {
        image.resized(maxPixels: maxPixels).jpegData(compressionQuality: jpegQuality)
    }
}

extension UIImage {
    /// Scaled down (never up) so the long side is at most `maxPixels` actual pixels, whatever the
    /// image's or the screen's scale.
    func resized(maxPixels: CGFloat) -> UIImage {
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        let factor = min(maxPixels / pixels.width, maxPixels / pixels.height, 1)
        if factor == 1 { return self }
        let target = CGSize(width: (pixels.width * factor).rounded(), height: (pixels.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // the default is the screen's (3×), which is how 1024 became 3072
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
