import Foundation

/// The kind of content captured from the pasteboard.
enum ClipKind: String, CaseIterable, Sendable {
    case text
    case url
    case image
    case file

    var displayName: String {
        switch self {
        case .text: return "Text"
        case .url: return "Link"
        case .image: return "Image"
        case .file: return "File"
        }
    }

    var systemImageName: String {
        switch self {
        case .text: return "doc.plaintext"
        case .url: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }
}
