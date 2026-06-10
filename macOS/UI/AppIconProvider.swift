import AppKit

/// Resolves source-app icons and Paste-style card header colors.
///
/// Icons are looked up once per bundle ID via `NSWorkspace` and cached. The
/// header color is the average color of a downsampled render of that icon
/// (also cached). Apps that cannot be resolved fall back to a stable,
/// saturated palette picked by an FNV-1a hash of the seed so the same app
/// keeps the same hue across launches.
@MainActor
enum AppIconProvider {
    private static let iconCache = NSCache<NSString, NSImage>()
    private static let colorCache = NSCache<NSString, NSColor>()

    /// Paste-like saturated fallback palette.
    private static let fallbackPalette: [NSColor] = [
        NSColor(calibratedRed: 0.91, green: 0.12, blue: 0.81, alpha: 1), // magenta
        NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.96, alpha: 1), // blue
        NSColor(calibratedRed: 0.61, green: 0.33, blue: 0.96, alpha: 1), // purple
        NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.15, alpha: 1), // orange
        NSColor(calibratedRed: 0.13, green: 0.69, blue: 0.67, alpha: 1), // teal
        NSColor(calibratedRed: 0.95, green: 0.33, blue: 0.55, alpha: 1), // pink
        NSColor(calibratedRed: 0.42, green: 0.40, blue: 0.94, alpha: 1), // indigo
        NSColor(calibratedRed: 0.91, green: 0.26, blue: 0.21, alpha: 1), // red
    ]

    private static let genericIcon: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        let symbol = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard")
        return symbol?.withSymbolConfiguration(configuration) ?? NSImage(size: NSSize(width: 26, height: 26))
    }()

    // MARK: - Icons

    /// The app icon for a bundle ID, or a generic clipboard glyph.
    static func icon(forBundleID bundleID: String?) -> NSImage {
        guard let bundleID, !bundleID.isEmpty else { return genericIcon }
        let key = bundleID as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return genericIcon
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache.setObject(icon, forKey: key)
        return icon
    }

    // MARK: - Header colors

    /// Dominant (average) color of the app icon, or a stable palette color
    /// derived from `fallbackSeed` when the app cannot be resolved.
    static func headerColor(forBundleID bundleID: String?, fallbackSeed: String) -> NSColor {
        guard let bundleID, !bundleID.isEmpty else { return paletteColor(forSeed: fallbackSeed) }
        let key = bundleID as NSString
        if let cached = colorCache.object(forKey: key) { return cached }
        guard
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil,
            let average = averageColor(of: icon(forBundleID: bundleID))
        else {
            return paletteColor(forSeed: fallbackSeed)
        }
        let color = normalized(average)
        colorCache.setObject(color, forKey: key)
        return color
    }

    static func paletteColor(forSeed seed: String) -> NSColor {
        // FNV-1a: Swift's hashValue is randomized per process, unusable here.
        var hash: UInt32 = 2_166_136_261
        for byte in seed.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return fallbackPalette[Int(hash % UInt32(fallbackPalette.count))]
    }

    // MARK: - Color math

    /// Average color of an 8x8 downsampled render, alpha-weighted so the
    /// transparent rounded corners of macOS app icons do not skew the result.
    private static func averageColor(of image: NSImage) -> NSColor? {
        let sample = 8
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: sample, pixelsHigh: sample,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: sample, height: sample),
            from: .zero, operation: .copy, fraction: 1
        )
        context.flushGraphics()

        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        for x in 0..<sample {
            for y in 0..<sample {
                guard let pixel = bitmap.colorAt(x: x, y: y) else { continue }
                let alpha = Double(pixel.alphaComponent)
                guard alpha > 0.1 else { continue }
                red += Double(pixel.redComponent) * alpha
                green += Double(pixel.greenComponent) * alpha
                blue += Double(pixel.blueComponent) * alpha
                weight += alpha
            }
        }
        guard weight > 0 else { return nil }
        return NSColor(
            calibratedRed: red / weight, green: green / weight, blue: blue / weight, alpha: 1
        )
    }

    /// Nudges a muddy average toward the saturated, mid-brightness range the
    /// reference design uses, without changing the hue.
    private static func normalized(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let boostedSaturation = saturation < 0.02 ? saturation : min(max(saturation, 0.45), 0.95)
        let clampedBrightness = min(max(brightness, 0.40), 0.78)
        return NSColor(
            calibratedHue: hue, saturation: boostedSaturation, brightness: clampedBrightness, alpha: 1
        )
    }
}
