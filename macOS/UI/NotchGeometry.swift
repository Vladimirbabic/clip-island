import AppKit

/// Describes the black "notch" region a panel can bloom out of. On notched
/// MacBooks this is the real hardware notch; on external or older displays we
/// synthesize a small pill at the top-center of the menu bar so the effect
/// still reads the same.
struct NotchGeometry {
    let screen: NSScreen
    let hasNotch: Bool
    /// Width/height of the black cutout the bloom starts from, in points.
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    /// The notch is always horizontally centered on its display.
    var centerX: CGFloat { screen.frame.midX }
    /// Absolute top edge of the display (notch sits flush with it).
    var topY: CGFloat { screen.frame.maxY }

    /// Resolves the geometry to bloom from, preferring a real notch on any
    /// connected display, then the display under the mouse, then the main one.
    static func resolve(preferredScreen: NSScreen?) -> NotchGeometry? {
        guard let screen = preferredScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            return nil
        }
        // Bloom from the real notch only when the user is on the built-in
        // display; on any other screen (e.g. an external monitor on a docked
        // laptop) synthesize a top-center pill so the panel appears where the
        // cursor and active app actually are — not on the closed-away laptop.
        if hasHardwareNotch(screen), let geometry = fromHardwareNotch(screen) {
            return geometry
        }
        // Synthetic cutout: a pill the height of the menu bar, centered up top.
        let menuBarHeight = max(22, screen.frame.maxY - screen.visibleFrame.maxY)
        return NotchGeometry(
            screen: screen,
            hasNotch: false,
            notchWidth: 180,
            notchHeight: menuBarHeight
        )
    }

    private static func hasHardwareNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil
    }

    private static func fromHardwareNotch(_ screen: NSScreen) -> NotchGeometry? {
        let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
        let width = screen.frame.width - leftWidth - rightWidth
        let height = screen.safeAreaInsets.top
        guard width > 0, height > 0 else { return nil }
        return NotchGeometry(screen: screen, hasNotch: true, notchWidth: width, notchHeight: height)
    }
}
