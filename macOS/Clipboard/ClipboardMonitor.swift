import AppKit
import Foundation
import OSLog

/// Polls `NSPasteboard.general` for changes and records new clips through
/// `ClipStore`. Reads in priority order: file URLs, images (with any text
/// flavor attached), web URLs, text.
@MainActor
final class ClipboardMonitor {
    private static let pollInterval: TimeInterval = 0.4
    private static let pollTolerance: TimeInterval = 0.1

    /// Pasteboard marker types whose presence means the contents must never be
    /// recorded (transient values, password managers, auto-generated data).
    private static let excludedTypeIdentifiers = Set(AppConstants.excludedPasteboardTypes)

    private let logger = Logger(subsystem: "com.vladbabic.clipstory", category: "clipboard")
    private let store: ClipStore
    private let pasteboard: NSPasteboard = .general
    private var timer: Timer?
    private var lastChangeCount: Int
    /// Single in-flight image encode; a newer image capture cancels it, and a
    /// stale result (pasteboard changed again) is dropped on commit.
    private var imageEncodeTask: Task<Void, Never>?

    /// Invoked after every successfully inserted clip. `AppDelegate` uses this
    /// to kick off link-metadata fetches for `.url` items.
    var onItemCaptured: ((ClipItem) -> Void)?

    init(store: ClipStore) {
        self.store = store
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            // The timer is scheduled on the main run loop, so this always
            // executes on the main actor.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.poll()
            }
        }
        timer.tolerance = Self.pollTolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Called by `PasteService` with the change count returned by
    /// `NSPasteboard.clearContents()`, so the app's own pasteboard writes are
    /// acknowledged (change count stays in sync) but never re-captured.
    func noteOwnWrite(changeCount: Int) {
        lastChangeCount = changeCount
    }

    // MARK: - Polling

    private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        guard !UserDefaults.standard.bool(forKey: AppConstants.capturePausedKey) else { return }
        guard !containsExcludedType() else { return }
        capture(changeCount: changeCount)
    }

    private func containsExcludedType() -> Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains { Self.excludedTypeIdentifiers.contains($0.rawValue) }
    }

    // MARK: - Reading

    private func capture(changeCount: Int) {
        let sourceApp = NSWorkspace.shared.frontmostApplication
        let appName = sourceApp?.localizedName
        let bundleID = sourceApp?.bundleIdentifier

        if let content = readFileURLs(appName: appName, bundleID: bundleID) {
            insert(content)
            return
        }

        let rawString = pasteboard.string(forType: .string)
        if let rawImageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            scheduleImageCapture(
                rawImageData: rawImageData,
                rawString: rawString,
                appName: appName,
                bundleID: bundleID,
                changeCount: changeCount
            )
            return
        }

        if let content = stringContent(raw: rawString, appName: appName, bundleID: bundleID) {
            insert(content)
        }
    }

    private func insert(_ content: CapturedContent) {
        guard let item = store.insert(content) else { return }
        onItemCaptured?(item)
    }

    /// Captures ALL file URLs on the pasteboard: one absolute path per line in
    /// `text`, and a `fileName` of either the single file's name or "N files".
    private func readFileURLs(appName: String?, bundleID: String?) -> CapturedContent? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
            let first = urls.first
        else { return nil }

        let paths = urls.map { $0.path(percentEncoded: false) }
        let fileName = urls.count == 1 ? first.lastPathComponent : "\(urls.count) files"
        return CapturedContent(
            kind: .file,
            text: paths.joined(separator: "\n"),
            fileName: fileName,
            sourceAppName: appName,
            sourceAppBundleID: bundleID
        )
    }

    private func stringContent(raw: String?, appName: String?, bundleID: String?) -> CapturedContent? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if Self.isAbsoluteWebURL(trimmed) {
            return CapturedContent(
                kind: .url,
                text: trimmed,
                sourceAppName: appName,
                sourceAppBundleID: bundleID
            )
        }
        return CapturedContent(
            kind: .text,
            text: raw,
            sourceAppName: appName,
            sourceAppBundleID: bundleID
        )
    }

    private static func isAbsoluteWebURL(_ string: String) -> Bool {
        guard !string.contains(where: \.isWhitespace) else { return false }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    // MARK: - Image capture (async encode)

    /// Everything needed to insert an image-bearing clip once the (slow) PNG
    /// re-encode finishes off the main actor.
    private struct PendingImageCapture: Sendable {
        let kind: ClipKind
        let text: String?
        let sourceAppName: String?
        let sourceAppBundleID: String?
        let changeCount: Int
    }

    /// Pasteboard reads and the kind decision happen on the main actor; only
    /// pixel work (decode, downscale, PNG encode) runs detached. When the
    /// pasteboard carries BOTH image data and a non-empty string (e.g.
    /// spreadsheet cells), both flavors are stored.
    private func scheduleImageCapture(
        rawImageData: Data,
        rawString: String?,
        appName: String?,
        bundleID: String?,
        changeCount: Int
    ) {
        var kind: ClipKind = .image
        var text: String?
        if let rawString {
            let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if Self.isAbsoluteWebURL(trimmed) {
                    // A lone URL riding along with image data stays an image clip.
                    text = trimmed
                } else {
                    // Substantial text: the clip is text, with the image kept
                    // as a second flavor for paste-back.
                    kind = .text
                    text = rawString
                }
            }
        }
        let pending = PendingImageCapture(
            kind: kind,
            text: text,
            sourceAppName: appName,
            sourceAppBundleID: bundleID,
            changeCount: changeCount
        )
        let maxByteCount = AppConstants.maxImageByteCount
        let logger = logger

        imageEncodeTask?.cancel()
        imageEncodeTask = Task.detached(priority: .utility) { [weak self] in
            guard
                let image = NSImage(data: rawImageData),
                let pngData = ImageEncoder.png(from: image, maxByteCount: maxByteCount)
            else {
                logger.error("Dropping image clip: decode/encode failed or image exceeds size cap")
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.commitImageCapture(pending, pngData: pngData)
            }
        }
    }

    private func commitImageCapture(_ pending: PendingImageCapture, pngData: Data) {
        // Drop stale results: the pasteboard changed again while encoding.
        guard lastChangeCount == pending.changeCount else { return }
        insert(CapturedContent(
            kind: pending.kind,
            text: pending.text,
            imageData: pngData,
            sourceAppName: pending.sourceAppName,
            sourceAppBundleID: pending.sourceAppBundleID
        ))
    }
}

/// PNG re-encoding with proportional downscaling so stored images stay under
/// the CloudKit-friendly size cap. Pure pixel work — safe off the main actor.
private enum ImageEncoder {
    static func png(from image: NSImage, maxByteCount: Int) -> Data? {
        guard var cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        var encoded = pngData(from: cgImage)
        while let data = encoded, data.count > maxByteCount, max(cgImage.width, cgImage.height) > 64 {
            guard let smaller = halved(cgImage) else { break }
            cgImage = smaller
            encoded = pngData(from: cgImage)
        }
        guard let data = encoded, data.count <= maxByteCount else { return nil }
        return data
    }

    private static func pngData(from cgImage: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private static func halved(_ cgImage: CGImage) -> CGImage? {
        let width = max(cgImage.width / 2, 1)
        let height = max(cgImage.height / 2, 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
