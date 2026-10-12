import ImageIO
import XCTest
@testable import OldMansBookClub

/// #204 (docs/SEND_REQUIREMENTS.md, S6) — a photo is sent at 2048 pixels on its long side. It was
/// meant to be 1024 but measured in points, so 3072 px on a 3× phone: too big for a batch of ten.
final class PhotoUploadTests: XCTestCase {

    private func image(width: CGFloat, height: CGFloat, scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: width / scale, height: height / scale), format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width / scale, height: height / scale))
            UIColor.systemOrange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width / scale / 2, height: height / scale / 3))
        }
    }

    /// The pixel size of the JPEG that would be sent.
    private func sentPixels(_ image: UIImage) throws -> CGSize {
        let jpeg = try XCTUnwrap(PhotoUpload.jpeg(image))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return CGSize(width: try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int),
                      height: try XCTUnwrap(props[kCGImagePropertyPixelHeight] as? Int))
    }

    func testACameraPhotoIsSentAt2048PixelsOnItsLongSide() throws {
        XCTAssertEqual(try sentPixels(image(width: 4032, height: 3024)), CGSize(width: 2048, height: 1536))
        XCTAssertEqual(try sentPixels(image(width: 3024, height: 4032)), CGSize(width: 1536, height: 2048))
    }

    func testTheScreensScaleDoesNotMultiplyTheSize() throws {
        // A screenshot is a 3× image: 430 × 932 points, 1290 × 2796 pixels. The size is in pixels.
        XCTAssertEqual(try sentPixels(image(width: 1290, height: 2796, scale: 3)), CGSize(width: 945, height: 2048))
    }

    func testASmallPhotoIsSentAsItIsNotEnlarged() throws {
        XCTAssertEqual(try sentPixels(image(width: 800, height: 600)), CGSize(width: 800, height: 600))
    }
}
