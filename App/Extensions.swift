import UIKit

extension UIImage {
    func resizedForUpload(maxDimension: CGFloat = 1024) -> UIImage {
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1)
        if scale == 1 { return self }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
