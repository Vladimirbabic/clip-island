import Foundation
import SwiftData

/// Synced settings handling. The history limit must come from the synced
/// AppSettings record — see AppSettings.swift for the data-loss rationale.
extension ClipStore {
    private static let localInsertCountKey = "localInsertCount"

    /// The effective limit for display purposes (synced value, else default).
    var historyLimit: Int {
        syncedHistoryLimit() ?? AppConstants.defaultHistoryLimit
    }

    /// True once a synced limit exists (i.e. pruning is active).
    var hasSyncedHistoryLimit: Bool {
        syncedHistoryLimit() != nil
    }

    /// The synced limit, or nil when no AppSettings record is visible yet.
    func syncedHistoryLimit() -> Int? {
        guard let settings = resolvedSettings(), settings.historyLimitValue > 0 else { return nil }
        return settings.historyLimitValue
    }

    /// Explicit user choice: creates or updates the synced record and prunes.
    func setHistoryLimit(_ limit: Int) {
        guard limit > 0 else { return }
        let settings = resolvedSettings() ?? insertSettingsRecord()
        settings.historyLimitValue = limit
        settings.updatedAt = Date()
        UserDefaults.standard.set(limit, forKey: AppConstants.historyLimitKey)
        do {
            try saveAndPrune()
        } catch {
            logger.error("Failed to save history limit: \(error)")
        }
    }

    /// Returns the deterministic primary AppSettings record, merging away
    /// duplicates created by concurrent first-runs on multiple devices.
    /// Primary = oldest createdAt (tie: smallest dedupID); the *value* adopted
    /// is the one with the newest updatedAt, so an explicit user choice on any
    /// device beats silent defaults (which use updatedAt == .distantPast).
    func resolvedSettings() -> AppSettings? {
        do {
            let all = try context.fetch(FetchDescriptor<AppSettings>())
            guard !all.isEmpty else { return nil }
            let sorted = all.sorted { a, b in
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.dedupID.uuidString < b.dedupID.uuidString
            }
            let primary = sorted[0]
            guard sorted.count > 1 else { return primary }
            if let newest = all.max(by: { $0.updatedAt < $1.updatedAt }),
               newest.updatedAt > primary.updatedAt {
                primary.historyLimitValue = newest.historyLimitValue
                primary.updatedAt = newest.updatedAt
            }
            for duplicate in sorted.dropFirst() {
                context.delete(duplicate)
            }
            save()
            return primary
        } catch {
            logger.error("Failed to resolve settings: \(error)")
            return nil
        }
    }

    /// Counts inserts captured on THIS device. Once the device has clearly
    /// produced more clips than the default limit and still no synced record
    /// exists anywhere, create the default one (updatedAt = .distantPast so
    /// any explicit choice wins later merges). Counting only local inserts —
    /// not synced-in items — prevents a freshly synced companion device from
    /// creating the record (and pruning!) before the other device's settings
    /// record has arrived.
    func noteLocalInsert() {
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: Self.localInsertCountKey) + 1
        defaults.set(count, forKey: Self.localInsertCountKey)
        guard count > AppConstants.defaultHistoryLimit, resolvedSettings() == nil else { return }
        let settings = insertSettingsRecord()
        settings.historyLimitValue = AppConstants.defaultHistoryLimit
        save()
    }

    private func insertSettingsRecord() -> AppSettings {
        let settings = AppSettings()
        context.insert(settings)
        return settings
    }
}
