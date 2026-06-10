import Foundation
import SwiftData

/// Cross-device dedupe. `insert` only dedupes locally; two devices copying
/// the same content (e.g. via Universal Clipboard) each create a record and
/// CloudKit happily keeps both. This sweep collapses them after sync.
///
/// Called on macOS panel-show and iOS app-foreground. The keeper choice is
/// deterministic (newest createdAt, tie-broken by smallest dedupID) so two
/// devices sweeping concurrently converge on the same survivor instead of
/// deleting each other's keeper.
extension ClipStore {
    func dedupeSweep() {
        do {
            let all = try context.fetch(FetchDescriptor<ClipItem>())
            let groups = Dictionary(grouping: all, by: \.contentHash)
            var changed = false
            for (_, members) in groups where members.count > 1 {
                let ranked = members.sorted { a, b in
                    if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
                    return a.dedupID.uuidString < b.dedupID.uuidString
                }
                let keeper = ranked[0]
                for duplicate in ranked.dropFirst() {
                    if duplicate.isPinned { keeper.isPinned = true }
                    if keeper.pinboard == nil { keeper.pinboard = duplicate.pinboard }
                    if keeper.sourceAppName == nil { keeper.sourceAppName = duplicate.sourceAppName }
                    if keeper.sourceAppBundleID == nil { keeper.sourceAppBundleID = duplicate.sourceAppBundleID }
                    if keeper.linkTitle == nil { keeper.linkTitle = duplicate.linkTitle }
                    context.delete(duplicate)
                    changed = true
                }
            }
            // Also merge any duplicated synced-settings records.
            _ = resolvedSettings()
            if changed {
                try context.save()
            }
        } catch {
            logger.error("Dedupe sweep failed: \(error)")
        }
    }
}
