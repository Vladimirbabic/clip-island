import Foundation

/// Immutable value describing content read from a pasteboard, before it is
/// persisted as a `ClipItem`.
struct CapturedContent: Sendable, Equatable {
    let kind: ClipKind
    let text: String?
    let imageData: Data?
    let fileName: String?
    let sourceAppName: String?
    let sourceAppBundleID: String?

    init(
        kind: ClipKind,
        text: String? = nil,
        imageData: Data? = nil,
        fileName: String? = nil,
        sourceAppName: String? = nil,
        sourceAppBundleID: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.imageData = imageData
        self.fileName = fileName
        self.sourceAppName = sourceAppName
        self.sourceAppBundleID = sourceAppBundleID
    }

    /// Stable hash of the user-visible content (not the source app), so the
    /// same content copied twice in a row collapses into one history entry.
    var contentHash: String {
        ContentHasher.hash(kind: kind, text: text, imageData: imageData, fileName: fileName)
    }
}
