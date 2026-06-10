import Foundation
import SwiftData

/// Singleton-ish synced settings record. The history limit MUST be a synced
/// value: per-device limits combined with synced deletes let the device with
/// the smallest limit permanently destroy other devices' history (see
/// ClipStore.saveAndPrune, which refuses to prune until one of these records
/// has synced in).
///
/// CloudKit cannot enforce a singleton, so concurrent creation on two devices
/// can briefly yield multiple records; `ClipStore.resolvedSettings()` picks a
/// deterministic primary and merges the rest.
@Model
final class AppSettings {
    var createdAt: Date = Date()
    /// Deterministic tie-breaker when merging duplicate records.
    var dedupID: UUID = UUID()
    /// When the user last explicitly changed a setting. Records created as
    /// silent defaults use `.distantPast` so an explicit choice on any device
    /// always wins the merge.
    var updatedAt: Date = Date.distantPast
    /// Maximum number of unpinned, un-boarded history items. 0 means "unset".
    var historyLimitValue: Int = 0

    init(historyLimitValue: Int = 0, updatedAt: Date = Date.distantPast) {
        self.historyLimitValue = historyLimitValue
        self.updatedAt = updatedAt
    }
}
