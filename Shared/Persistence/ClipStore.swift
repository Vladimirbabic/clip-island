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

    /// Inserts user-created content that did not come from the system
    /// pasteboard. Manual items are saved content: they are pinned, can be
    /// assigned directly to a page, and are excluded from clear/prune.
    @discardableResult
    func insertManual(_ content: CapturedContent, to board: Pinboard? = nil) -> ClipItem? {
        do {
            let item = ClipItem(content: content)
            item.isPinned = true
            item.pinboard = board
            item.isSavedToPage = board != nil
            item.sourceAppName = content.sourceAppName ?? "ClipStory"
            item.sourceAppBundleID = content.sourceAppBundleID
            item.contentHash = "manual:\(item.dedupID.uuidString):\(content.contentHash)"
            context.insert(item)
            try context.save()
            return item
        } catch {
            logger.error("Failed to insert manual clip: \(error)")
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

    /// Deletes only disposable clipboard history. Pinned clips and clips saved
    /// to a page/pinboard are user-saved content and must never be cleared by
    /// history cleanup.
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

    /// Attaches an asynchronously generated preview image to a file clip.
    /// File paths can sync to iOS, but the underlying macOS file cannot, so
    /// image files need a compact persisted preview to render cross-device.
    func updateFilePreview(contentHash: String, imageData: Data?, recognizedText: String? = nil) {
        guard let imageData, imageData.count <= AppConstants.maxImageByteCount else { return }
        do {
            var descriptor = FetchDescriptor<ClipItem>(
                predicate: #Predicate { $0.contentHash == contentHash },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            guard
                let item = try context.fetch(descriptor).first,
                item.kind == .file,
                !item.isDeleted,
                item.imageData == nil
            else { return }

            item.imageData = imageData
            if let recognizedText, !recognizedText.isEmpty, item.recognizedText == nil {
                item.recognizedText = recognizedText
            }
            try context.save()
        } catch {
            logger.error("Failed to update file preview: \(error)")
        }
    }

    func updateRecognizedText(for item: ClipItem, text: String?) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return
        }
        item.recognizedText = text
        save()
    }

    func updateRecognizedText(contentHash: String, text: String?) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return
        }
        do {
            var descriptor = FetchDescriptor<ClipItem>(
                predicate: #Predicate { $0.contentHash == contentHash },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            guard let item = try context.fetch(descriptor).first, !item.isDeleted else { return }
            item.recognizedText = text
            try context.save()
        } catch {
            logger.error("Failed to update recognized text: \(error)")
        }
    }

    func rename(_ item: ClipItem, to title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        item.customTitle = trimmed.isEmpty ? nil : trimmed
        item.isPinned = true
        save()
    }

    func updateText(_ item: ClipItem, to text: String) {
        guard item.kind == .text || item.kind == .url else { return }
        item.text = text
        item.customTitle = item.customTitle
        item.isPinned = true
        item.contentHash = editedContentHash(for: item)
        save()
    }

    func updateImageData(_ item: ClipItem, imageData: Data, recognizedText: String? = nil) {
        guard item.kind == .image || item.kind == .file || item.kind == .url else { return }
        item.imageData = imageData
        if let recognizedText, !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.recognizedText = recognizedText
        }
        item.isPinned = true
        item.contentHash = editedContentHash(for: item)
        save()
    }

    private func editedContentHash(for item: ClipItem) -> String {
        let hash = ContentHasher.hash(
            kind: item.kind,
            text: item.text,
            imageData: item.imageData,
            fileName: item.fileName,
            fileData: item.fileData,
            fileTypeIdentifier: item.fileTypeIdentifier
        )
        return "edited:\(item.dedupID.uuidString):\(hash)"
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
        if try pruneOverflowUsingStorePredicate(to: limit) {
            return
        }

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

    private func pruneOverflowUsingStorePredicate(to limit: Int) throws -> Bool {
        let predicate = #Predicate<ClipItem> {
            !$0.isPinned && $0.pinboard == nil && !$0.isSavedToPage
        }
        let overflow: [ClipItem]
        do {
            let count = try context.fetchCount(FetchDescriptor<ClipItem>(predicate: predicate))
            let overflowCount = count - limit
            guard overflowCount > 0 else { return true }

            var descriptor = FetchDescriptor<ClipItem>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )
            descriptor.fetchLimit = overflowCount
            overflow = try context.fetch(descriptor)
        } catch {
            // Optional relationship nil-predicates are not reliable on every
            // SwiftData runtime, so callers fall back to the in-memory path.
            return false
        }

        for item in overflow {
            context.delete(item)
        }
        try context.save()
        return true
    }

    /// Items eligible for pruning/clearing: not pinned and not saved to a page.
    /// Tries a store-level predicate first; SwiftData's support for optional
    /// relationship nil-comparisons has OS-version quirks, so fall back to an
    /// in-memory filter rather than failing the save.
    func fetchPrunable() throws -> [ClipItem] {
        do {
            let predicate = #Predicate<ClipItem> {
                !$0.isPinned && $0.pinboard == nil && !$0.isSavedToPage
            }
            return try context.fetch(FetchDescriptor<ClipItem>(predicate: predicate))
        } catch {
            let all = try context.fetch(FetchDescriptor<ClipItem>())
            return all.filter { !$0.isPinned && $0.pinboard == nil && !$0.isSavedToPage }
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
