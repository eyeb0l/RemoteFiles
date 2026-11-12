#if os(iOS)
import XCTest
import UIKit
@testable import RemoteFilesUI

@MainActor final class SearchFieldBackgroundTests: XCTestCase {
    private func traits(_ style: UIUserInterfaceStyle, scale: CGFloat) -> UITraitCollection {
        UITraitCollection { $0.userInterfaceStyle = style; $0.displayScale = scale }
    }

    private func centrePixel(_ image: UIImage) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let middle = CGRect(x: cgImage.width / 2, y: cgImage.height / 2, width: 1, height: 1)
        context.draw(try XCTUnwrap(cgImage.cropping(to: middle)), in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel
    }

    func testCapsuleKeepsItsPointSizeAndStretchesOnlyBetweenItsEnds() {
        let image = RemoteFilesStyle.searchFieldBackground()
        let scale = UIGraphicsImageRendererFormat.preferred().scale
        for style in [UIUserInterfaceStyle.light, .dark] {
            let resolved = image.imageAsset?.image(with: traits(style, scale: scale)) ?? image
            // At scale 1 the field would be three times taller than the system's.
            XCTAssertEqual(resolved.size, CGSize(width: 46, height: 44))
            XCTAssertEqual(resolved.scale, scale)
            XCTAssertEqual(resolved.capInsets, UIEdgeInsets(top: 22, left: 22, bottom: 22, right: 22))
            XCTAssertEqual(resolved.resizingMode, .stretch)
        }
    }

    func testCapsuleFollowsLightAndDarkAppearance() throws {
        let image = RemoteFilesStyle.searchFieldBackground()
        let asset = try XCTUnwrap(image.imageAsset)
        let scale = UIGraphicsImageRendererFormat.preferred().scale
        let light = try centrePixel(asset.image(with: traits(.light, scale: scale)))
        let dark = try centrePixel(asset.image(with: traits(.dark, scale: scale)))
        XCTAssertEqual(light, [255, 255, 255, 255])
        // Translucent grey, which reads as the glass at rest over a dark bar.
        XCTAssertLessThan(dark[3], 128)
        XCTAssertGreaterThan(dark[3], 0)
    }
}
#endif
