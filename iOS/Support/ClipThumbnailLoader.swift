import ImageIO
import UIKit

/// Downsamples stored image payloads (which can be multi-megabyte PNGs) into
/// small row thumbnails via ImageIO, cached by content hash so list scrolling
/// never decodes a full image twice. Detail views may still decode full-size.
@MainActor
enum ClipThumbnailLoader {
    static let maxThumbnailPixelSize = 120

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    static func thumbnail(for item: ClipItem) -> UIImage? {
        guard let data = item.imageData, !data.isEmpty else { return nil }
        let key = cacheKey(for: item)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = makeThumbnail(from: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private static func cacheKey(for item: ClipItem) -> NSString {
        let key = item.contentHash.isEmpty ? item.dedupID.uuidString : item.contentHash
        return key as NSString
    }

    private static func makeThumbnail(from data: Data) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary)
        else { return nil }

        // Stored PNGs carry no embedded thumbnail, so creation from the full
        // image must be forced or this returns nil for almost every item.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxThumbnailPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
