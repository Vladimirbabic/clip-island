import Foundation
import SwiftData

/// One clipboard history entry, synced across devices via CloudKit.
///
/// CloudKit-backed SwiftData models must give every stored property a default
/// value (or make it optional), must not use `@Attribute(.unique)`, and any
/// relationships must be optional. Keep those constraints when editing.
@Model
final class ClipItem {
    var createdAt: Date = Date()
    var kindRawValue: String = ClipKind.text.rawValue
    var text: String?
    @Attribute(.externalStorage) var imageData: Data?
    var fileName: String?
    var sourceAppName: String?
    var sourceAppBundleID: String?
    var isPinned: Bool = false
    /// SHA-256 of the content, used to de-duplicate copies. Not unique at the
    /// store level (CloudKit forbids it) — see `ClipStore.dedupeSweep()`.
    var contentHash: String = ""
    /// Stable cross-device identity used as a deterministic tie-breaker when
    /// the dedupe sweep collapses items with equal `createdAt`.
    var dedupID: UUID = UUID()
    /// og:title fetched for `.url` items (macOS fills this asynchronously).
    var linkTitle: String?
    /// Pinboard membership. Items on a pinboard are never pruned.
    var pinboard: Pinboard?

    init(content: CapturedContent, createdAt: Date = Date()) {
        self.createdAt = createdAt
        self.kindRawValue = content.kind.rawValue
        self.text = content.text
        self.imageData = content.imageData
        self.fileName = content.fileName
        self.sourceAppName = content.sourceAppName
        self.sourceAppBundleID = content.sourceAppBundleID
        self.contentHash = content.contentHash
    }

    var kind: ClipKind {
        ClipKind(rawValue: kindRawValue) ?? .text
    }

    /// Short human-readable summary for list rows and previews.
    var preview: String {
        switch kind {
        case .text, .url:
            let value = text ?? ""
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Empty text" : String(trimmed.prefix(300))
        case .image:
            return "Image"
        case .file:
            return fileName ?? "File"
        }
    }
}
