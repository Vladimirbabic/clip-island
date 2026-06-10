import UIKit

/// Reads the system pasteboard into a `CapturedContent`. The cheap `has*` /
/// `contains` checks run first so nothing is read (and no paste banner is
/// shown) when the pasteboard is empty or holds excluded content.
@MainActor
enum ClipboardReader {
    private static let sourceName = "iPhone"

    static func readCurrentContent() -> CapturedContent? {
        let pasteboard = UIPasteboard.general

        // Never capture transient or concealed content (password managers
        // etc.). Type checks do not count as a read, so no banner appears.
        guard !pasteboard.contains(
            pasteboardTypes: AppConstants.excludedPasteboardTypes, inItemSet: nil
        ) else {
            return nil
        }

        if pasteboard.hasImages, let image = pasteboard.image,
           let data = encodedImageData(from: image) {
            return CapturedContent(kind: .image, imageData: data, sourceAppName: sourceName)
        }
        if pasteboard.hasURLs, let url = pasteboard.url {
            return CapturedContent(kind: .url, text: url.absoluteString, sourceAppName: sourceName)
        }
        if pasteboard.hasStrings, let string = pasteboard.string,
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CapturedContent(kind: .text, text: string, sourceAppName: sourceName)
        }
        return nil
    }

    private static func encodedImageData(from image: UIImage) -> Data? {
        guard let data = image.pngData() else { return nil }
        guard data.count > AppConstants.maxImageByteCount else { return data }
        return downscaledPNGData(from: image)
    }

    /// Repeatedly shrinks the image until its PNG encoding fits the sync
    /// budget, giving up below a minimum useful size.
    private static func downscaledPNGData(from image: UIImage) -> Data? {
        let minimumDimension: CGFloat = 64
        var size = image.size
        for _ in 0..<6 {
            size = CGSize(width: size.width * 0.7, height: size.height * 0.7)
            guard size.width >= minimumDimension, size.height >= minimumDimension else { return nil }

            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let resized = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            if let data = resized.pngData(), data.count <= AppConstants.maxImageByteCount {
                return data
            }
        }
        return nil
    }
}
