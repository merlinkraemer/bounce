import SwiftUI
import UIKit
import ImageIO

/// Decodes and downsamples artwork once, then reuses the SwiftUI `Image`.
/// Shared by track/playlist row and header call sites so full-res
/// `UIImage(data:)` does not run on every scroll/body pass.
final class ArtworkImageCache {
    static let shared = ArtworkImageCache()

    private struct Key: Hashable {
        let id: UUID
        let pointSize: Int
        let byteCount: Int
    }

    private var cache: [Key: Image] = [:]
    private let lock = NSLock()
    private let maxEntries = 200

    func image(for id: UUID, data: Data?, pointSize: CGFloat) -> Image? {
        guard let data, !data.isEmpty else { return nil }

        let key = Key(
            id: id,
            pointSize: Int(pointSize.rounded()),
            byteCount: data.count
        )

        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[key] { return cached }

        guard let uiImage = Self.downsampledImage(from: data, pointSize: pointSize) else {
            return nil
        }
        let image = Image(uiImage: uiImage)
        if cache.count >= maxEntries { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        return image
    }

    private static func downsampledImage(from data: Data, pointSize: CGFloat) -> UIImage? {
        let maxPixels = max(1, Int((pointSize * UIScreen.main.scale).rounded()))
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}
