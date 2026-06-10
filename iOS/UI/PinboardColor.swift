import SwiftUI

/// Maps the shared, cross-platform pinboard color names
/// (`AppConstants.pinboardColorNames`) to SwiftUI colors.
enum PinboardColor {
    static func color(named name: String) -> Color {
        switch name {
        case "magenta": return Color(red: 0.91, green: 0.20, blue: 0.62)
        case "blue": return .blue
        case "purple": return .purple
        case "orange": return .orange
        case "teal": return .teal
        case "pink": return .pink
        case "indigo": return .indigo
        case "red": return .red
        case "yellow": return .yellow
        case "green": return .green
        default: return .gray
        }
    }

    static func displayName(for name: String) -> String {
        name.capitalized
    }
}
