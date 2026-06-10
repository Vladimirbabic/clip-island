import Foundation
import SwiftData

/// A named, colored collection of saved clips (Paste's "pinboards"), shown as
/// tabs on macOS and chips on iOS. CloudKit rules apply: defaults everywhere,
/// optional relationships, no unique attributes.
@Model
final class Pinboard {
    var name: String = ""
    var colorName: String = "magenta"
    var iconName: String = "square.grid.2x2"
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    /// Deterministic tie-breaker for cross-device ordering and merges.
    var dedupID: UUID = UUID()

    @Relationship(deleteRule: .nullify, inverse: \ClipItem.pinboard)
    var items: [ClipItem]?

    init(
        name: String,
        colorName: String = "magenta",
        iconName: String = "square.grid.2x2",
        sortOrder: Int = 0
    ) {
        self.name = name
        self.colorName = colorName
        self.iconName = iconName
        self.sortOrder = sortOrder
    }

    var displayName: String {
        name.isEmpty ? "Untitled" : name
    }
}
