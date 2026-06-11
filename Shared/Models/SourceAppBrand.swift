import Foundation
import SwiftData

/// Synced per-app branding for clip card headers: the icon-derived header
/// color and a small icon image. Only macOS can resolve other apps' icons
/// (NSWorkspace has no iOS counterpart), so Macs publish these records and
/// iOS renders cards from them. CloudKit rules apply: defaults everywhere,
/// no unique attributes — duplicates merge in `ClipStore.brandsByBundleID`.
@Model
final class SourceAppBrand {
    var bundleID: String = ""
    var appName: String = ""
    /// RRGGBB header color produced by the Mac's dominant-icon-hue pipeline.
    var colorHex: String = ""
    /// 64×64 PNG of the app icon for cross-device display.
    @Attribute(.externalStorage) var iconPNG: Data?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Deterministic tie-breaker for cross-device merges.
    var dedupID: UUID = UUID()

    init(bundleID: String) {
        self.bundleID = bundleID
    }
}
