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
    @Attribute(.externalStorage) var fileData: Data?
    var fileName: String?
    var fileTypeIdentifier: String?
    /// User-facing override used when a clip is renamed. Optional/additive for
    /// CloudKit migration safety.
    var customTitle: String?
    /// Text recognized locally from image/screenshot previews. Kept optional
    /// so older records remain valid and clips without images stay compact.
    var recognizedText: String?
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
    /// Denormalized page marker used by prune/clear. CloudKit can import a
    /// clip before its Pinboard record (and the relationship link) arrives;
    /// this scalar travels in the clip's own record, so page clips are never
    /// mistaken for disposable history during that window. Maintained by
    /// `ClipStore.assign`/`deletePinboard` and backfilled in `dedupeSweep`.
    var isSavedToPage: Bool = false

    init(content: CapturedContent, createdAt: Date = Date()) {
        self.createdAt = createdAt
        self.kindRawValue = content.kind.rawValue
        self.text = content.text
        self.imageData = content.imageData
        self.fileData = content.fileData
        self.fileName = content.fileName
        self.fileTypeIdentifier = content.fileTypeIdentifier
        self.recognizedText = content.recognizedText
        self.sourceAppName = content.sourceAppName
        self.sourceAppBundleID = content.sourceAppBundleID
        self.contentHash = content.contentHash
    }

    var kind: ClipKind {
        ClipKind(rawValue: kindRawValue) ?? .text
    }

    /// Short human-readable summary for list rows: the clip's name when
    /// renamed, else a content summary.
    var preview: String {
        trimmedCustomTitle ?? contentPreview
    }

    /// The user-given name (rename / note title), nil when unset or blank.
    var trimmedCustomTitle: String? {
        guard let customTitle else { return nil }
        let trimmed = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Card header title: the clip's name when renamed, else the kind label.
    var cardTitle: String {
        trimmedCustomTitle ?? kind.displayName
    }

    /// Summary of the actual content — what pasting this clip produces. Never
    /// the custom title: card bodies must always show real content.
    var contentPreview: String {
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
