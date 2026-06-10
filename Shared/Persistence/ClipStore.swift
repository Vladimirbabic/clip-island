import Foundation
import OSLog
import SwiftData

/// Central mutation API for clipboard history. Reads in the UI go through
/// `@Query`; all writes (insert, pin, assign, delete, prune) go through this
/// store so de-duplication and pruning behave identically on macOS and iOS.
@MainActor
final class ClipStore: ObservableObject {
    let container: ModelContainer

    let logger = Logger(subsystem: "com.vladbabic.clipstory", category: "store")

    var context: ModelContext { container.mainContext }

    init(container: ModelContainer) {
        self.container = container
    }

    /// Inserts captured content. If an item with identical content already
    /// exists, the newest such item is bumped to the top instead of
    /// duplicated. Returns the affected item, or nil when the insert failed.
    @discardableResult
    func insert(_ content: CapturedContent) -> ClipItem? {
        let hash = content.contentHash
        do {
            var descriptor = FetchDescriptor<ClipItem>(
                predicate: #Predicate { $0.contentHash == hash },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                existing.createdAt = Date()
                if let name = content.sourceAppName { existing.sourceAppName = name }
                if let bundleID = content.sourceAppBundleID { existing.sourceAppBundleID = bundleID }
                try saveAndPrune()
                return existing
            }

            let item = ClipItem(content: content)
            context.insert(item)
            try saveAndPrune()
            noteLocalInsert()
            return item
        } catch {
            logger.error("Failed to insert clip: \(error)")
            return nil
        }
    }

    func togglePin(_ item: ClipItem) {
        item.isPinned.toggle()
        save()
    }

    func delete(_ item: ClipItem) {
        context.delete(item)
        save()
    }

    /// Deletes history items that are neither pinned nor on a pinboard.
    func clearUnpinned() {
        do {
            for item in try fetchPrunable() {
                context.delete(item)
            }
            save()
        } catch {
            logger.error("Failed to clear history: \(error)")
        }
    }

    /// Attaches asynchronously fetched link metadata (og:title / preview
    /// image) to a `.url` item.
    func updateLinkMetadata(for item: ClipItem, title: String?, imageData: Data?) {
        guard item.kind == .url, !item.isDeleted else { return }
        if let title, !title.isEmpty { item.linkTitle = title }
        if let imageData, imageData.count <= AppConstants.maxImageByteCount, item.imageData == nil {
            item.imageData = imageData
        }
        save()
    }

    // MARK: - Pruning

    /// Saves, then prunes oldest prunable items beyond the *synced* history
    /// limit. Pruning is deliberately skipped until a synced AppSettings
    /// record is visible: a per-device default would let a freshly set up
    /// device delete history that another device's larger limit said to keep
    /// (deletes sync; per-device defaults don't).
    func saveAndPrune() throws {
        try context.save()
        guard let limit = syncedHistoryLimit() else { return }
        try prune(to: limit)
    }

    private func prune(to limit: Int) throws {
        guard limit > 0 else { return }
        let prunable = try fetchPrunable()
        guard prunable.count > limit else { return }
        let overflow = prunable
            .sorted { $0.createdAt > $1.createdAt }
            .dropFirst(limit)
        for item in overflow {
            context.delete(item)
        }
        try context.save()
    }

    /// Items eligible for pruning/clearing: not pinned and not on a pinboard.
    /// Tries a store-level predicate first; SwiftData's support for optional
    /// relationship nil-comparisons has OS-version quirks, so fall back to an
    /// in-memory filter rather than failing the save.
    func fetchPrunable() throws -> [ClipItem] {
        do {
            let predicate = #Predicate<ClipItem> { !$0.isPinned && $0.pinboard == nil }
            return try context.fetch(FetchDescriptor<ClipItem>(predicate: predicate))
        } catch {
            let all = try context.fetch(FetchDescriptor<ClipItem>())
            return all.filter { !$0.isPinned && $0.pinboard == nil }
        }
    }

    func save() {
        do {
            try context.save()
        } catch {
            logger.error("Failed to save context: \(error)")
        }
    }
}
