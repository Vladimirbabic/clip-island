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
            let dominant = dominantColor(of: icon(forBundleID: bundleID))
        else {
            return paletteColor(forSeed: fallbackSeed)
        }
        let color = normalized(dominant)
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

    /// Signature color of a 16x16 downsampled render. Pixels vote into hue
    /// buckets weighted by vividness (alpha × saturation × brightness), so a
    /// multicolor icon yields its dominant hue instead of all hues averaging
    /// into mud, and near-gray pixels (chrome, shadows, white plates) abstain.
    /// Effectively monochrome icons return their gray so `normalized` can
    /// keep them deliberately neutral.
    private static func dominantColor(of image: NSImage) -> NSColor? {
        let sample = 16
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

        let buckets = 12
        var bucketWeight = [Double](repeating: 0, count: buckets)
        var hueSum = [Double](repeating: 0, count: buckets)
        var saturationSum = [Double](repeating: 0, count: buckets)
        var brightnessSum = [Double](repeating: 0, count: buckets)
        var totalAlpha = 0.0, vividAlpha = 0.0
        var grayBrightness = 0.0, grayAlpha = 0.0

        for x in 0..<sample {
            for y in 0..<sample {
                guard let pixel = bitmap.colorAt(x: x, y: y) else { continue }
                let alpha = Double(pixel.alphaComponent)
                guard alpha > 0.1 else { continue }
                totalAlpha += alpha
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, a: CGFloat = 0
                pixel.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &a)
                guard saturation >= 0.15, brightness >= 0.2 else {
                    grayBrightness += Double(brightness) * alpha
                    grayAlpha += alpha
                    continue
                }
                vividAlpha += alpha
                let vividness = alpha * Double(saturation) * Double(brightness)
                let bucket = min(Int(Double(hue) * Double(buckets)), buckets - 1)
                bucketWeight[bucket] += vividness
                hueSum[bucket] += Double(hue) * vividness
                saturationSum[bucket] += Double(saturation) * vividness
                brightnessSum[bucket] += Double(brightness) * vividness
            }
        }
        guard totalAlpha > 0 else { return nil }

        // Too little color to be the icon's identity (e.g. a tiny accent on
        // an otherwise gray icon): report the gray instead.
        if vividAlpha < totalAlpha * 0.04 {
            guard grayAlpha > 0 else { return nil }
            return NSColor(calibratedWhite: grayBrightness / grayAlpha, alpha: 1)
        }

        guard
            let best = bucketWeight.indices.max(by: { bucketWeight[$0] < bucketWeight[$1] }),
            bucketWeight[best] > 0
        else { return nil }
        let weight = bucketWeight[best]
        return NSColor(
            calibratedHue: hueSum[best] / weight,
            saturation: saturationSum[best] / weight,
            brightness: brightnessSum[best] / weight,
            alpha: 1
        )
    }

    /// Pushes the dominant color into the rich, mid-brightness range the
    /// reference design uses, without changing the hue. Genuinely gray icons
    /// become a calm slate — never fake-saturated into mud.
    private static func normalized(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if saturation < 0.12 {
            return NSColor(calibratedHue: 0.61, saturation: 0.12, brightness: 0.42, alpha: 1)
        }
        let boostedSaturation = min(max(saturation * 1.4, 0.72), 0.92)
        // Yellow reads as olive/khaki below ~0.75 brightness; everything else
        // is richest in the upper-mid range.
        let isYellowBand = (0.08...0.22).contains(hue)
        let minimumBrightness: CGFloat = isYellowBand ? 0.75 : 0.52
        let clampedBrightness = min(max(brightness, minimumBrightness), 0.80)
        return NSColor(
            calibratedHue: hue, saturation: boostedSaturation, brightness: clampedBrightness, alpha: 1
        )
    }
}
