import AppKit
import QuartzCore
import SwiftData
import SwiftUI

extension Notification.Name {
    /// Posted every time the history panel is presented so the SwiftUI content
    /// can reset search state and refocus the search field.
    static let clipStoryPanelDidShow = Notification.Name("clipStoryPanelDidShow")
}

/// Borderless, non-activating panel that becomes key so the search field is
/// typeable without stealing activation from the frontmost app.
private final class HistoryPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape, when no responder consumed it
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Owns the notch-bloom panel: a black, rounded-bottom panel anchored to the
/// top-center of the display that grows out of the MacBook notch (or a
/// synthetic top-center pill on displays without one) when the clipboard is
/// opened, and collapses back into it when dismissed.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private static let panelWidth: CGFloat = 720
    private static let panelHeight: CGFloat = 392
    private static let cornerRadiusFull: CGFloat = 24
    private static let cornerRadiusNotch: CGFloat = 10
    private static let openDuration: CFTimeInterval = 0.26
    private static let closeDuration: CFTimeInterval = 0.18

    private let panel: HistoryPanel
    private let store: ClipStore
    private let pasteService: PasteService

    /// Black, rounded container the bloom mask is applied to.
    private let containerView = NSView()
    /// SwiftUI content; faded in after the black has bloomed open.
    private var hostingView: NSView?
    /// Opaque layer whose frame/cornerRadius animate to reveal the container.
    private let maskLayer = CALayer()
    /// Top inset that keeps the content clear of the physical notch; updated
    /// per display when the panel is shown.
    private var contentTopInset: NSLayoutConstraint?
    /// Geometry the panel opened with, reused on hide so the collapse matches
    /// the exact notch/pill it bloomed from (even if the mouse moved screens).
    private var activeGeometry: NotchGeometry?

    /// App that was frontmost when the panel was last shown; paste target.
    private var pasteTarget: NSRunningApplication?
    private var isHiding = false

    init(
        store: ClipStore,
        container: ModelContainer,
        syncStatus: CloudSyncStatus,
        pasteService: PasteService
    ) {
        self.store = store
        self.pasteService = pasteService
        self.panel = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()
        configurePanel()
        installContent(store: store, container: container, syncStatus: syncStatus)
    }

    // MARK: - Public API

    func toggle() {
        if panel.isVisible && !isHiding {
            hide()
        } else {
            show()
        }
    }

    func show() {
        isHiding = false
        // Never record ourselves as the paste target (e.g. when toggling via
        // the status item); keep the previous target instead.
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            pasteTarget = app
        }

        // Collapse cross-device duplicates before the history becomes visible.
        store.dedupeSweep()

        guard let geometry = resolveGeometry() else { return }
        activeGeometry = geometry
        panel.setFrame(panelFrame(for: geometry), display: false)
        // Render the rounded corners at native resolution on Retina displays.
        maskLayer.contentsScale = geometry.screen.backingScaleFactor

        // Keep the content below the physical notch / menu bar; the top strip
        // stays pure black so it blends into the notch.
        contentTopInset?.constant = geometry.notchHeight
        containerView.layoutSubtreeIfNeeded()

        let bloom = bloomRects(for: geometry)
        // Start collapsed inside the notch with the content hidden.
        applyMask(rect: bloom.notch, cornerRadius: Self.cornerRadiusNotch, animated: false)
        setContentVisible(false, animated: false)

        panel.makeKeyAndOrderFront(nil)

        if reduceMotion {
            applyMask(rect: bloom.full, cornerRadius: Self.cornerRadiusFull, animated: false)
            setContentVisible(true, animated: true, duration: 0.16, delay: 0)
        } else {
            applyMask(
                rect: bloom.full,
                cornerRadius: Self.cornerRadiusFull,
                animated: true,
                duration: Self.openDuration,
                timing: .easeOut
            )
            setContentVisible(true, animated: true, duration: 0.16, delay: Self.openDuration * 0.4)
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .clipStoryPanelDidShow, object: nil)
        }
    }

    func hide() {
        guard panel.isVisible, !isHiding else { return }
        isHiding = true

        guard !reduceMotion, let geometry = activeGeometry else {
            finishHide()
            return
        }

        let bloom = bloomRects(for: geometry)
        setContentVisible(false, animated: true, duration: 0.12, delay: 0)
        applyMask(
            rect: bloom.notch,
            cornerRadius: Self.cornerRadiusNotch,
            animated: true,
            duration: Self.closeDuration,
            timing: .easeIn
        ) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isHiding else { return }
                self.finishHide()
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Test hook: `--keep-open` keeps the panel up when it loses key focus
        // so UI tests can drive it with synthetic keystrokes. Never set in
        // normal use.
        if ProcessInfo.processInfo.arguments.contains("--keep-open") { return }
        // A SwiftUI .alert (Clear History / Delete Pinboard) or a context menu
        // presents its own key window; collapsing the panel then would yank it
        // out from under them. Defer a tick and only dismiss when key truly
        // left our app (no key window of ours remains).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if NSApp.keyWindow == nil {
                self.hide()
            }
        }
    }

    // MARK: - Setup

    private func configurePanel() {
        // Sit above the menu bar so the black panel visually merges with the
        // hardware notch at the very top of the screen.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // window shadow would frame the full rect; the mask owns the shape
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.onCancel = { [weak self] in
            self?.hide()
        }
    }

    private func installContent(
        store: ClipStore,
        container: ModelContainer,
        syncStatus: CloudSyncStatus
    ) {
        let rootView = HistoryView(
            store: store,
            syncStatus: syncStatus,
            onPaste: { [weak self] item in self?.paste(item) },
            onClose: { [weak self] in self?.hide() }
        )
        .modelContainer(container)
        .environmentObject(store)

        let host = NSHostingView(rootView: rootView)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true

        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.black.cgColor
        containerView.layer?.masksToBounds = false
        containerView.addSubview(host)
        let topInset = host.topAnchor.constraint(equalTo: containerView.topAnchor)
        contentTopInset = topInset
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            topInset,
            host.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        // Bottom corners are rounded; the top stays flush with the screen edge.
        maskLayer.backgroundColor = NSColor.black.cgColor
        maskLayer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        maskLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        containerView.layer?.mask = maskLayer

        hostingView = host
        panel.contentView = containerView
    }

    // MARK: - Bloom animation

    private struct BloomRects {
        let notch: CGRect
        let full: CGRect
    }

    private func bloomRects(for geometry: NotchGeometry) -> BloomRects {
        let width = Self.panelWidth
        let height = Self.panelHeight
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        // In a non-flipped layer the origin is bottom-left, so the notch sits at
        // the top: high y, horizontally centered within the panel.
        let notch = CGRect(
            x: (width - geometry.notchWidth) / 2,
            y: height - geometry.notchHeight,
            width: geometry.notchWidth,
            height: geometry.notchHeight
        )
        return BloomRects(notch: notch, full: full)
    }

    private func applyMask(
        rect: CGRect,
        cornerRadius: CGFloat,
        animated: Bool,
        duration: CFTimeInterval = 0,
        timing: CAMediaTimingFunctionName = .easeOut,
        completion: (() -> Void)? = nil
    ) {
        let newBounds = CGRect(origin: .zero, size: rect.size)
        let newPosition = CGPoint(x: rect.midX, y: rect.midY)

        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            maskLayer.bounds = newBounds
            maskLayer.position = newPosition
            maskLayer.cornerRadius = cornerRadius
            CATransaction.commit()
            completion?()
            return
        }

        // Read from the presentation layer so interrupting a bloom mid-flight
        // continues from where it visually is, rather than snapping.
        let presentation = maskLayer.presentation()
        let oldBounds = presentation?.bounds ?? maskLayer.bounds
        let oldPosition = presentation?.position ?? maskLayer.position
        let oldRadius = presentation?.cornerRadius ?? maskLayer.cornerRadius
        let timingFunction = CAMediaTimingFunction(name: timing)

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        CATransaction.setDisableActions(true)
        maskLayer.bounds = newBounds
        maskLayer.position = newPosition
        maskLayer.cornerRadius = cornerRadius

        maskLayer.add(basicAnimation("bounds", from: NSValue(rect: oldBounds), to: NSValue(rect: newBounds), duration: duration, timing: timingFunction), forKey: "bounds")
        maskLayer.add(basicAnimation("position", from: NSValue(point: oldPosition), to: NSValue(point: newPosition), duration: duration, timing: timingFunction), forKey: "position")
        maskLayer.add(basicAnimation("cornerRadius", from: oldRadius, to: cornerRadius, duration: duration, timing: timingFunction), forKey: "cornerRadius")
        CATransaction.commit()
    }

    private func basicAnimation(
        _ keyPath: String,
        from: Any,
        to: Any,
        duration: CFTimeInterval,
        timing: CAMediaTimingFunction
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timing
        return animation
    }

    private func setContentVisible(
        _ visible: Bool,
        animated: Bool,
        duration: CFTimeInterval = 0,
        delay: CFTimeInterval = 0
    ) {
        guard let layer = hostingView?.layer else { return }
        let target: Float = visible ? 1 : 0

        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = target
            CATransaction.commit()
            return
        }

        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = target
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = target
        animation.duration = duration
        animation.beginTime = CACurrentMediaTime() + delay
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "opacity")
    }

    // MARK: - Helpers

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func resolveGeometry() -> NotchGeometry? {
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        return NotchGeometry.resolve(preferredScreen: mouseScreen)
    }

    private func panelFrame(for geometry: NotchGeometry) -> NSRect {
        let width = Self.panelWidth
        let height = Self.panelHeight
        var originX = geometry.centerX - width / 2
        // Keep the panel fully on its screen; left-align if it is wider than
        // the screen (otherwise the standard clamp inverts and pushes the
        // panel off the left edge on very narrow displays).
        let frame = geometry.screen.frame
        let maxX = max(frame.minX, frame.maxX - width)
        originX = min(max(originX, frame.minX), maxX)
        let originY = geometry.topY - height
        return NSRect(x: originX, y: originY, width: width, height: height)
    }

    private func finishHide() {
        isHiding = false
        activeGeometry = nil
        panel.orderOut(nil)
    }

    private func paste(_ item: ClipItem) {
        let target = pasteTarget
        isHiding = false
        // Order out synchronously (no animation) so the panel has fully
        // resigned key before the synthesized ⌘V fires — otherwise the paste
        // lands in our own search field.
        panel.orderOut(nil)
        pasteService.paste(item: item, into: target)
    }
}
