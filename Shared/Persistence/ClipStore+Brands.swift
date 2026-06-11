import Foundation
import SwiftData

/// Per-app brand records (header color + icon) published by macOS so iOS can
/// render identical card headers.
extension ClipStore {
    /// All brands keyed by bundle ID. Cross-device duplicates (two Macs
    /// publishing the same app concurrently) are merged deterministically:
    /// the newest `updatedAt` values win, the record with the smallest
    /// dedupID survives.
    func brandsByBundleID() -> [String: SourceAppBrand] {
        do {
            let all = try context.fetch(FetchDescriptor<SourceAppBrand>())
            var merged: [String: SourceAppBrand] = [:]
            var changed = false
            for brand in all {
                guard let existing = merged[brand.bundleID] else {
                    merged[brand.bundleID] = brand
                    continue
                }
                let keeper = existing.dedupID.uuidString < brand.dedupID.uuidString ? existing : brand
                let duplicate = keeper === existing ? brand : existing
                if duplicate.updatedAt > keeper.updatedAt {
                    keeper.appName = duplicate.appName
                    keeper.colorHex = duplicate.colorHex
                    keeper.iconPNG = duplicate.iconPNG
                    keeper.updatedAt = duplicate.updatedAt
                }
                context.delete(duplicate)
                merged[brand.bundleID] = keeper
                changed = true
            }
            if changed {
                save()
            }
            return merged
        } catch {
            logger.error("Failed to fetch app brands: \(error)")
            return [:]
        }
    }

    /// Creates or refreshes the brand for a bundle ID. Saves only when
    /// something actually changed, so per-capture publishing stays cheap.
    func upsertBrand(bundleID: String, appName: String?, colorHex: String, iconPNG: Data?) {
        guard !bundleID.isEmpty, !colorHex.isEmpty else { return }
        do {
            let predicate = #Predicate<SourceAppBrand> { $0.bundleID == bundleID }
            let existing = try context.fetch(FetchDescriptor<SourceAppBrand>(predicate: predicate))
            if let brand = existing.first {
                let nameChanged = appName.map { $0 != brand.appName } ?? false
                guard brand.colorHex != colorHex || brand.iconPNG != iconPNG || nameChanged else {
                    return
                }
                if let appName { brand.appName = appName }
                brand.colorHex = colorHex
                brand.iconPNG = iconPNG
                brand.updatedAt = Date()
            } else {
                let brand = SourceAppBrand(bundleID: bundleID)
                brand.appName = appName ?? ""
                brand.colorHex = colorHex
                brand.iconPNG = iconPNG
                context.insert(brand)
            }
            try context.save()
        } catch {
            logger.error("Failed to upsert app brand: \(error)")
        }
    }
}
