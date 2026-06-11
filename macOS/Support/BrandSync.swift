import AppKit
import Foundation
import SwiftData

/// Publishes per-app brands (header color + icon PNG) into the synced store
/// so iOS renders the same card headers. Runs on the Mac because only macOS
/// can resolve other apps' icons.
@MainActor
enum BrandSync {
    /// Bundle IDs already published this launch; upsertBrand is cheap but a
    /// capture burst should not refetch/re-render icons repeatedly.
    private static var publishedThisLaunch = Set<String>()

    /// Publishes the brand for one captured clip's source app.
    static func publish(forBundleID bundleID: String?, appName: String?, store: ClipStore) {
        guard let bundleID, !bundleID.isEmpty, !publishedThisLaunch.contains(bundleID) else { return }
        publishedThisLaunch.insert(bundleID)
        let hex = AppIconProvider.headerColorHex(forBundleID: bundleID, fallbackSeed: bundleID)
        store.upsertBrand(
            bundleID: bundleID,
            appName: appName,
            colorHex: hex,
            iconPNG: AppIconProvider.iconPNGData(forBundleID: bundleID)
        )
    }

    /// Backfills brands for every source app already in history, so clips
    /// captured before this feature get colored/iconed on iOS too.
    static func backfill(store: ClipStore) {
        do {
            let items = try store.context.fetch(FetchDescriptor<ClipItem>())
            var seen = Set<String>()
            for item in items {
                guard let bundleID = item.sourceAppBundleID, !bundleID.isEmpty,
                      !seen.contains(bundleID) else { continue }
                seen.insert(bundleID)
                publish(forBundleID: bundleID, appName: item.sourceAppName, store: store)
            }
        } catch {
            // Best-effort: brands refresh again on the next capture/launch.
        }
    }
}
