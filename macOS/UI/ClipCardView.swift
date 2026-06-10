import AppKit
import ImageIO
import SwiftUI

/// Paste-style clip card: colored app header, kind-specific preview body,
/// character-count footer with a quick-paste badge.
@MainActor
struct ClipCardView: View {
    static let cardSize = CGSize(width: 190, height: 228)

    private static let backgroundColor = Color(red: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x20 / 255.0)
    private static let selectionColor = Color(red: 0x34 / 255.0, green: 0x78 / 255.0, blue: 0xF6 / 255.0)
    /// Above this UTF-8 byte count the footer shows a size, not a character
    /// count (grapheme counting a huge clip on every render is too slow).
    private static let characterCountByteLimit = 10_000

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    let item: ClipItem
    let isSelected: Bool
    /// Zero-based index among the visible cards; first nine get a ⌘-badge.
    let quickPasteIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            header
            contentBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .background(Self.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 16.5)
                    .stroke(Self.selectionColor, lineWidth: 3)
                    .padding(-3.5)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.kind.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: Date()))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            Image(nsImage: AppIconProvider.icon(forBundleID: item.sourceAppBundleID))
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .frame(height: 43, alignment: .top)
        .background(headerBackground)
    }

    private var headerBackground: LinearGradient {
        let seed = item.sourceAppBundleID ?? item.sourceAppName ?? item.kindRawValue
        let base = AppIconProvider.headerColor(forBundleID: item.sourceAppBundleID, fallbackSeed: seed)
        let bottom = base.blended(withFraction: 0.15, of: .black) ?? base
        return LinearGradient(
            colors: [Color(nsColor: base), Color(nsColor: bottom)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Body

    @ViewBuilder
    private var contentBody: some View {
        switch item.kind {
        case .text:
            // Always the capped preview — never the raw (possibly huge) text.
            Text(item.preview)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(9)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
        case .url:
            urlBody
        case .image:
            imageBody
        case .file:
            fileBody
        }
    }

    @ViewBuilder
    private var urlBody: some View {
        let thumbnail = item.imageData.flatMap {
            ClipThumbnailCache.thumbnail(forData: $0, key: item.contentHash)
        }
        if thumbnail == nil && item.linkTitle == nil {
            VStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Text(item.text ?? "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let thumbnail {
                    Color.clear
                        .overlay(Image(nsImage: thumbnail).resizable().scaledToFill())
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.linkTitle ?? item.text ?? "")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(thumbnail == nil ? 5 : 2)
                    if item.linkTitle != nil, let host = URL(string: item.text ?? "")?.host {
                        Text(host)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var imageBody: some View {
        if let data = item.imageData,
           let thumbnail = ClipThumbnailCache.thumbnail(forData: data, key: item.contentHash) {
            Color.clear
                .overlay(Image(nsImage: thumbnail).resizable().scaledToFill())
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if let pixels = ClipThumbnailCache.pixelSize(forData: data, key: item.contentHash) {
                        Text("\(Int(pixels.width)) \u{00D7} \(Int(pixels.height))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .environment(\.colorScheme, .dark)
                            .padding(8)
                    }
                }
        } else {
            Image(systemName: "photo")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var fileBody: some View {
        if let thumbnail = filePreviewThumbnail {
            Color.clear
                .overlay(Image(nsImage: thumbnail).resizable().scaledToFill())
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    Text(item.fileName ?? item.preview)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .environment(\.colorScheme, .dark)
                        .padding(8)
                }
        } else {
            VStack(spacing: 8) {
                Image(systemName: item.kind.systemImageName)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white.opacity(0.55))
                Text(item.fileName ?? item.preview)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filePreviewThumbnail: NSImage? {
        if let data = item.imageData {
            return ClipThumbnailCache.thumbnail(forData: data, key: item.contentHash)
        }
        guard let url = firstExistingFileURL, Self.isPreviewableImageFile(url) else {
            return nil
        }
        return ClipThumbnailCache.thumbnail(forURL: url, key: filePreviewCacheKey(for: url))
    }

    private var firstExistingFileURL: URL? {
        let paths = (item.text ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        return paths.lazy
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func isPreviewableImageFile(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "heic", "webp", "tif", "tiff", "gif", "bmp"]
            .contains(url.pathExtension.lowercased())
    }

    private func filePreviewCacheKey(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let fileSize = values?.fileSize ?? 0
        return "file:\(url.path):\(modifiedAt):\(fileSize)"
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 0) {
            if let footerText {
                Text(footerText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let quickPasteIndex, quickPasteIndex < 9 {
                HStack(spacing: 3) {
                    Image(systemName: "list.dash")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text("\(quickPasteIndex + 1)")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.5))
                .help("\u{2318}\(quickPasteIndex + 1) pastes this clip")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 23)
    }

    private var footerText: String? {
        switch item.kind {
        case .text, .url:
            guard let text = item.text else { return nil }
            let byteCount = text.utf8.count // O(1) for native strings
            if byteCount > Self.characterCountByteLimit {
                return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
            }
            let count = text.count
            guard count != 1 else { return "1 character" }
            let formatted = Self.countFormatter.string(from: NSNumber(value: count)) ?? String(count)
            return "\(formatted) characters"
        case .image:
            guard let data = item.imageData else { return nil }
            return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        case .file:
            return nil
        }
    }
}

// MARK: - Thumbnail cache

/// ImageIO-based downsampling so card rendering never decodes a full-size
/// `imageData` payload (`NSImage(data:)` per row is far too slow). Both the
/// thumbnail and the original pixel dimensions are cached by content hash.
@MainActor
enum ClipThumbnailCache {
    private static let thumbnails = NSCache<NSString, NSImage>()
    private static let dimensions = NSCache<NSString, NSValue>()
    private static let maxPixelSize = 480

    static func thumbnail(forData data: Data, key: String) -> NSImage? {
        let cacheKey = key as NSString
        if let cached = thumbnails.object(forKey: cacheKey) { return cached }
        guard let source = makeSource(for: data) else { return nil }
        return thumbnail(from: source, cacheKey: cacheKey)
    }

    static func thumbnail(forURL url: URL, key: String) -> NSImage? {
        let cacheKey = key as NSString
        if let cached = thumbnails.object(forKey: cacheKey) { return cached }
        let options = [kCGImageSourceShouldCache: false] as [CFString: Any]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        return thumbnail(from: source, cacheKey: cacheKey)
    }

    private static func thumbnail(from source: CGImageSource, cacheKey: NSString) -> NSImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as [CFString: Any]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        thumbnails.setObject(image, forKey: cacheKey)
        return image
    }

    /// Original pixel dimensions, read from image metadata (no decode).
    static func pixelSize(forData data: Data, key: String) -> CGSize? {
        let cacheKey = key as NSString
        if let cached = dimensions.object(forKey: cacheKey) { return cached.sizeValue }
        guard
            let source = makeSource(for: data),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let size = CGSize(width: width, height: height)
        dimensions.setObject(NSValue(size: size), forKey: cacheKey)
        return size
    }

    private static func makeSource(for data: Data) -> CGImageSource? {
        let options = [kCGImageSourceShouldCache: false] as [CFString: Any]
        return CGImageSourceCreateWithData(data as CFData, options as CFDictionary)
    }
}
