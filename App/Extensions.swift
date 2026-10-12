import UIKit

extension UIImage {
    /// For avatars and covers. `maxDimension` is in points, so the result is that × the screen's
    /// scale in pixels. Chat photos use `PhotoUpload` (an exact pixel size) instead.
    func resizedForUpload(maxDimension: CGFloat = 1024) -> UIImage {
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1)
        if scale == 1 { return self }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
