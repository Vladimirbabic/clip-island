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
            var changed = false

            // Backfill the page marker for records written by builds that
            // predate it. Never cleared here: a nil pinboard with the flag
            // set may just mean the Pinboard record is still syncing in.
            for item in all where item.pinboard != nil && !item.isSavedToPage {
                item.isSavedToPage = true
                changed = true
            }

            let groups = Dictionary(grouping: all, by: \.contentHash)
            for (_, members) in groups where members.count > 1 {
                let ranked = members.sorted { a, b in
                    if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
                    return a.dedupID.uuidString < b.dedupID.uuidString
                }
                let keeper = ranked[0]
                for duplicate in ranked.dropFirst() {
                    // Marked as saved to a page whose record/relationship has
                    // not synced in yet — deleting now would lose the
                    // membership. A later sweep collapses the pair once the
                    // relationship materializes (or keeps both pages' copies).
                    if duplicate.isSavedToPage && duplicate.pinboard == nil { continue }
                    if keeper.isSavedToPage && keeper.pinboard == nil && duplicate.pinboard != nil {
                        continue
                    }
                    // Same content deliberately saved to two different pages
                    // is two pieces of user intent, not a sync duplicate.
                    if let keeperBoard = keeper.pinboard, let duplicateBoard = duplicate.pinboard,
                       keeperBoard.persistentModelID != duplicateBoard.persistentModelID {
                        continue
                    }
                    if duplicate.isPinned { keeper.isPinned = true }
                    if keeper.pinboard == nil, let board = duplicate.pinboard {
                        keeper.pinboard = board
                        keeper.isSavedToPage = true
                    }
                    if keeper.sourceAppName == nil { keeper.sourceAppName = duplicate.sourceAppName }
                    if keeper.sourceAppBundleID == nil { keeper.sourceAppBundleID = duplicate.sourceAppBundleID }
                    if keeper.linkTitle == nil { keeper.linkTitle = duplicate.linkTitle }
                    if keeper.customTitle == nil { keeper.customTitle = duplicate.customTitle }
                    if keeper.recognizedText == nil { keeper.recognizedText = duplicate.recognizedText }
                    if keeper.imageData == nil { keeper.imageData = duplicate.imageData }
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
