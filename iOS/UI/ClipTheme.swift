import SwiftUI
import UIKit

/// Centralized true-black theme for the iOS app: pure black canvas with
/// #1C1C1E card surfaces so the kind-icon and pinboard colors carry the
/// accent.
enum ClipTheme {
    /// Pure black app canvas.
    static let background = Color.black
    /// Card / capsule surface color (#1C1C1E, the dark-mode grouped cell
    /// color, used explicitly because the canvas is forced pure black).
    static let cardFill = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    /// Fill for the selected pinboard chip.
    static let chipSelectedFill = Color.white.opacity(0.12)

    static let cardCornerRadius: CGFloat = 12
    /// Horizontal screen margin around each row card.
    static let cardHorizontalMargin: CGFloat = 16
    /// Vertical gap between adjacent row cards.
    static let cardSpacing: CGFloat = 5
    /// Row content insets; clears the card margins above so content stays
    /// inside the rounded card.
    static let cardRowInsets = EdgeInsets(top: 12, leading: 30, bottom: 12, trailing: 24)

    /// Translucent-black navigation bar chrome (standard and scroll-edge),
    /// applied once at launch. UIKit appearance is used because SwiftUI's
    /// `toolbarBackground` cannot produce a black-tinted blur.
    @MainActor
    static func configureChrome() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        appearance.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        appearance.shadowColor = .clear

        let navigationBar = UINavigationBar.appearance()
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
    }
}
