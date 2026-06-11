import AppKit
import Foundation
import LinkPresentation
import SwiftData

/// Fetches og:title / preview images for `.url` clips via LinkPresentation
/// and persists them through `ClipStore.updateLinkMetadata`. Failures are
/// swallowed silently: link previews are best-effort and offline is normal.
@MainActor
final class LinkMetadataService {
    private static let fetchTimeout: TimeInterval = 10
    /// Hard stop for the downscale-by-halves loop.
    private static let maxDownscaleAttempts = 8
    private static let minImageDimension: CGFloat = 16

    private let store: ClipStore
    private var inFlight: Set<PersistentIdentifier> = []

    init(store: ClipStore) {
        self.store = store
    }

    func fetchMetadata(for item: ClipItem) {
        // Retry whenever the image is still missing — a clip that once got a
        // title without an image picks the image up on the next copy.
        guard item.kind == .url, item.linkTitle == nil || item.imageData == nil else { return }
        guard
            let urlText = item.text,
            let url = URL(string: urlText),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return }

        let id = item.persistentModelID
        guard !inFlight.contains(id) else { return }
        inFlight.insert(id)

        let provider = LPMetadataProvider()
        provider.timeout = Self.fetchTimeout

        Task { [weak self] in
            let metadata = try? await provider.startFetchingMetadata(for: url)
            var imageData: Data?
            if let imageProvider = metadata?.imageProvider {
                imageData = await Self.pngData(from: imageProvider)
            }
            // LinkPresentation often returns no image provider even when the
            // page declares og:image — fetch it directly, then fall back to
            // the site icon as a last resort.
            if imageData == nil {
                imageData = await Self.openGraphImageData(for: url)
            }
            if imageData == nil, let iconProvider = metadata?.iconProvider {
                imageData = await Self.pngData(from: iconProvider)
            }
            guard let self else { return }
            self.inFlight.remove(id)
            guard !item.isDeleted, metadata != nil || imageData != nil else { return }
            self.store.updateLinkMetadata(for: item, title: metadata?.title, imageData: imageData)
        }
    }

    // MARK: - Direct og:image fetch

    private static func openGraphImageData(for url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: fetchTimeout)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? true
        else { return nil }
        let head = data.prefix(512 * 1024)
        guard
            let html = String(data: head, encoding: .utf8)
                ?? String(data: head, encoding: .isoLatin1),
            let imageURL = OpenGraphParser.imageURL(inHTML: html, baseURL: url),
            let (imageData, imageResponse) = try? await URLSession.shared.data(from: imageURL),
            (imageResponse as? HTTPURLResponse).map({ $0.statusCode < 400 }) ?? true,
            let image = NSImage(data: imageData)
        else { return nil }
        return encodePNG(image, maxByteCount: AppConstants.maxImageByteCount)
    }

    // MARK: - Image extraction

    private static func pngData(from provider: NSItemProvider) async -> Data? {
        guard provider.canLoadObject(ofClass: NSImage.self) else { return nil }
        let image: NSImage? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                continuation.resume(returning: object as? NSImage)
            }
        }
        guard let image else { return nil }
        return encodePNG(image, maxByteCount: AppConstants.maxImageByteCount)
    }

    /// PNG-encodes, downscaling by halves until the payload fits the synced
    /// image budget. Returns nil when even a tiny render is too large.
    private static func encodePNG(_ image: NSImage, maxByteCount: Int) -> Data? {
        var size = image.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        for _ in 0..<maxDownscaleAttempts {
            guard let data = renderPNG(image, at: size) else { return nil }
            if data.count <= maxByteCount { return data }
            size = NSSize(width: size.width / 2, height: size.height / 2)
            guard size.width >= minImageDimension, size.height >= minImageDimension else {
                return nil
            }
        }
        return nil
    }

    private static func renderPNG(_ image: NSImage, at size: NSSize) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(Int(size.width), 1),
            pixelsHigh: max(Int(size.height), 1),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()
        return bitmap.representation(using: .png, properties: [:])
    }
}
