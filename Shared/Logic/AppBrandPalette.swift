import Foundation

/// Cross-platform color vocabulary for card headers. Both apps derive
/// fallback colors from the same seed hash and exchange icon-derived colors
/// as hex strings, so a clip renders with the identical header color on
/// macOS and iOS.
enum AppBrandPalette {
    /// Paste-like saturated fallback palette (RGB 0...1), used when an app's
    /// icon-derived brand is unavailable on either platform.
    static let fallback: [(red: Double, green: Double, blue: Double)] = [
        (0.91, 0.12, 0.81), // magenta
        (0.22, 0.48, 0.96), // blue
        (0.61, 0.33, 0.96), // purple
        (0.95, 0.55, 0.15), // orange
        (0.13, 0.69, 0.67), // teal
        (0.95, 0.33, 0.55), // pink
        (0.42, 0.40, 0.94), // indigo
        (0.91, 0.26, 0.21), // red
    ]

    /// Stable palette index for a seed. FNV-1a: Swift's hashValue is
    /// randomized per process (and differs across platforms), unusable here.
    static func fallbackIndex(forSeed seed: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in seed.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Int(hash % UInt32(fallback.count))
    }

    /// Uppercase RRGGBB encoding (no leading #).
    static func hex(red: Double, green: Double, blue: Double) -> String {
        func clamp(_ value: Double) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(format: "%02X%02X%02X", clamp(red), clamp(green), clamp(blue))
    }

    /// Parses an RRGGBB string; nil for anything malformed.
    static func components(fromHex hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return (
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
