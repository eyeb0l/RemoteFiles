import Foundation
import ImageIO
import CoreGraphics

/// Immutable decoded pixels; ImageIO work and the 32 MiB decoded LRU live off MainActor.
public struct DisplayImage: @unchecked Sendable {
    public let image: CGImage
    public var cost: Int { image.bytesPerRow * image.height }
}
public actor RemoteImageDecoder {
    public static let shared = RemoteImageDecoder()
    private var images: [String: DisplayImage] = [:]
    private var order: [String] = []
    public func clear() { images.removeAll(); order.removeAll() }
    public func decode(_ file: URL, maxPixel: Int) throws -> DisplayImage {
        try Task.checkCancellation()
        let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(file.path):\(stamp):\(maxPixel)"
        if let image = images[key] { order.removeAll { $0 == key }; order.append(key); return image }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 400_000_000,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
              ] as CFDictionary) else { throw RemoteResourceError.notImage }
        try Task.checkCancellation()
        let value = DisplayImage(image: thumbnail)
        let limit = 32 * 1024 * 1024
        if value.cost <= limit {
            while !order.isEmpty && images.values.reduce(value.cost, { $0 + $1.cost }) > limit {
                images.removeValue(forKey: order.removeFirst())
            }
            images[key] = value; order.append(key)
        }
        return value
    }
}
