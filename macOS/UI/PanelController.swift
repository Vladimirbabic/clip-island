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
    private static let initialPanelWidth: CGFloat = 1_000
    private static let panelHeight: CGFloat = 324
    private static let cornerRadiusFull: CGFloat = 24
    private static let cornerRadiusNotch: CGFloat = 10
    private static let openDuration: CFTimeInterval = 0.42
    private static let closeDuration: CFTimeInterval = 0.22
    private static let contentFadeInDuration: CFTimeInterval = 0.30
    private static let contentFadeOutDuration: CFTimeInterval = 0.11
    private static let contentEntranceOffset: CGFloat = 18
    private static let openTiming = CAMediaTimingFunction(controlPoints: 0.16, 0.98, 0.18, 1.00)
    private static let closeTiming = CAMediaTimingFunction(controlPoints: 0.55, 0.00, 0.90, 0.60)
    private static let fadeTiming = CAMediaTimingFunction(controlPoints: 0.25, 0.85, 0.25, 1.00)
    private static let contentTiming = CAMediaTimingFunction(controlPoints: 0.16, 1.00, 0.30, 1.00)
    private static let openingSettleTiming = CAMediaTimingFunction(controlPoints: 0.20, 0.92, 0.20, 1.00)

    private let panel: HistoryPanel
    private let store: ClipStore
    private let pasteService: PasteService
    private let onCheckForUpdates: () -> Void

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
    private var activeAppObserver: NSObjectProtocol?
    private var rasterizationResetTask: DispatchWorkItem?
    private var isHiding = false

    init(
        store: ClipStore,
        container: ModelContainer,
        syncStatus: CloudSyncStatus,
        pasteService: PasteService,
        onCheckForUpdates: @escaping () -> Void
    ) {
        self.store = store
        self.pasteService = pasteService
        self.onCheckForUpdates = onCheckForUpdates
        self.panel = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.initialPanelWidth, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()
        configurePanel()
        observeActiveApplication()
        installContent(store: store, container: container, syncStatus: syncStatus)
    }

    deinit {
        if let activeAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeAppObserver)
        }
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
        rememberPasteTarget(NSWorkspace.shared.frontmostApplication)

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
            setTransitionRasterizationEnabled(true, scale: geometry.screen.backingScaleFactor)
            applyOpeningMask(
                rect: bloom.full,
                cornerRadius: Self.cornerRadiusFull,
                duration: Self.openDuration,
            )
            setContentVisible(
                true,
                animated: true,
                duration: Self.contentFadeInDuration,
                delay: Self.openDuration * 0.18,
                timing: Self.contentTiming,
                entrance: true
            )
            scheduleRasterizationReset(after: Self.openDuration + Self.contentFadeInDuration + 0.08)
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
        setTransitionRasterizationEnabled(true, scale: geometry.screen.backingScaleFactor)
        setContentVisible(false, animated: true, duration: 0.12, delay: 0)
        applyMask(
            rect: bloom.notch,
            cornerRadius: Self.cornerRadiusNotch,
            animated: true,
            duration: Self.closeDuration,
            timing: Self.closeTiming
        ) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isHiding else { return }
                self.finishHide()
            }
        }
    }

    func hideImmediatelyForExternalUI() {
        guard panel.isVisible || isHiding else { return }
        rasterizationResetTask?.cancel()
        maskLayer.removeAllAnimations()
        hostingView?.layer?.removeAllAnimations()
        containerView.layer?.removeAllAnimations()
        setContentVisible(false, animated: false)
        finishHide()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            guard self.panel.isVisible, !self.isHiding, !self.panel.isKeyWindow else { return }
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

    private func observeActiveApplication() {
        activeAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                self?.rememberPasteTarget(app)
            }
        }
    }

    private func rememberPasteTarget(_ app: NSRunningApplication?) {
        guard let app, isPasteTargetCandidate(app) else { return }
        pasteTarget = app
    }

    private func isPasteTargetCandidate(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && !app.isTerminated
            && app.activationPolicy != .prohibited
    }

    private func installContent(
        store: ClipStore,
        container: ModelContainer,
        syncStatus: CloudSyncStatus
    ) {
        let rootView = HistoryView(
            store: store,
            syncStatus: syncStatus,
            onCheckForUpdates: { [weak self] in self?.onCheckForUpdates() },
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
        maskLayer.allowsEdgeAntialiasing = true
        maskLayer.edgeAntialiasingMask = [
            .layerLeftEdge, .layerRightEdge, .layerBottomEdge, .layerTopEdge,
        ]
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
        let size = panelSize(for: geometry)
        let width = size.width
        let height = size.height
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
        timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeOut),
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

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        CATransaction.setDisableActions(true)
        maskLayer.bounds = newBounds
        maskLayer.position = newPosition
        maskLayer.cornerRadius = cornerRadius

        let group = CAAnimationGroup()
        group.animations = [
            basicAnimation("bounds", from: NSValue(rect: oldBounds), to: NSValue(rect: newBounds)),
            basicAnimation("position", from: NSValue(point: oldPosition), to: NSValue(point: newPosition)),
            basicAnimation("cornerRadius", from: oldRadius, to: cornerRadius),
        ]
        group.duration = duration
        group.timingFunction = timing
        maskLayer.add(group, forKey: "bloom")
        CATransaction.commit()
    }

    private func applyOpeningMask(
        rect: CGRect,
        cornerRadius: CGFloat,
        duration: CFTimeInterval,
        completion: (() -> Void)? = nil
    ) {
        let newBounds = CGRect(origin: .zero, size: rect.size)
        let newPosition = CGPoint(x: rect.midX, y: rect.midY)
        let overshootRect = openingOvershootRect(for: rect)
        let overshootBounds = CGRect(origin: .zero, size: overshootRect.size)
        let overshootPosition = CGPoint(x: overshootRect.midX, y: overshootRect.midY)
        let overshootRadius = cornerRadius + 3

        let presentation = maskLayer.presentation()
        let oldBounds = presentation?.bounds ?? maskLayer.bounds
        let oldPosition = presentation?.position ?? maskLayer.position
        let oldRadius = presentation?.cornerRadius ?? maskLayer.cornerRadius

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        CATransaction.setDisableActions(true)
        maskLayer.bounds = newBounds
        maskLayer.position = newPosition
        maskLayer.cornerRadius = cornerRadius

        let group = CAAnimationGroup()
        group.animations = [
            keyframeAnimation(
                "bounds",
                values: [
                    NSValue(rect: oldBounds),
                    NSValue(rect: overshootBounds),
                    NSValue(rect: newBounds),
                ],
                timingFunctions: [Self.openTiming, Self.openingSettleTiming]
            ),
            keyframeAnimation(
                "position",
                values: [
                    NSValue(point: oldPosition),
                    NSValue(point: overshootPosition),
                    NSValue(point: newPosition),
                ],
                timingFunctions: [Self.openTiming, Self.openingSettleTiming]
            ),
            keyframeAnimation(
                "cornerRadius",
                values: [oldRadius, overshootRadius, cornerRadius],
                timingFunctions: [Self.openTiming, Self.openingSettleTiming]
            ),
        ]
        group.duration = duration
        maskLayer.add(group, forKey: "bloom")
        CATransaction.commit()
    }

    private func openingOvershootRect(for rect: CGRect) -> CGRect {
        let horizontal = min(max(rect.width * 0.004, 4), 8)
        let vertical: CGFloat = 10
        // Keep the top edge welded to the screen edge; only the bottom edge
        // slightly overruns before settling back into the final rounded shape.
        return CGRect(
            x: rect.minX - horizontal,
            y: rect.minY - vertical,
            width: rect.width + horizontal * 2,
            height: rect.height + vertical
        )
    }

    private func basicAnimation(
        _ keyPath: String,
        from: Any,
        to: Any
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        return animation
    }

    private func keyframeAnimation(
        _ keyPath: String,
        values: [Any],
        timingFunctions: [CAMediaTimingFunction]
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = [0, 0.78, 1]
        animation.timingFunctions = timingFunctions
        return animation
    }

    private func setContentVisible(
        _ visible: Bool,
        animated: Bool,
        duration: CFTimeInterval = 0,
        delay: CFTimeInterval = 0,
        timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeOut),
        entrance: Bool = false
    ) {
        guard let layer = hostingView?.layer else { return }
        let target: Float = visible ? 1 : 0

        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = target
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
            return
        }

        let from = layer.presentation()?.opacity ?? layer.opacity
        let startTransform = layer.presentation()?.transform ?? layer.transform
        let targetTransform = CATransform3DIdentity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = target
        layer.transform = targetTransform
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = target
        animation.duration = duration
        animation.beginTime = CACurrentMediaTime() + delay
        animation.fillMode = .backwards
        animation.timingFunction = timing
        layer.add(animation, forKey: "opacity")

        if entrance {
            var fromTransform = CATransform3DMakeTranslation(0, Self.contentEntranceOffset, 0)
            fromTransform = CATransform3DScale(fromTransform, 0.986, 0.986, 1)
            var settleTransform = CATransform3DMakeTranslation(0, -1.5, 0)
            settleTransform = CATransform3DScale(settleTransform, 1.002, 1.002, 1)
            let transform = CAKeyframeAnimation(keyPath: "transform")
            transform.values = [
                CATransform3DIsIdentity(startTransform) ? fromTransform : startTransform,
                settleTransform,
                targetTransform,
            ]
            transform.keyTimes = [0, 0.74, 1]
            transform.timingFunctions = [Self.contentTiming, Self.openingSettleTiming]
            transform.duration = duration + 0.04
            transform.beginTime = CACurrentMediaTime() + delay
            transform.fillMode = .backwards
            layer.add(transform, forKey: "transform")
        } else if !visible {
            let transform = CABasicAnimation(keyPath: "transform")
            transform.fromValue = startTransform
            transform.toValue = CATransform3DMakeTranslation(0, Self.contentEntranceOffset * 0.35, 0)
            transform.duration = duration
            transform.beginTime = CACurrentMediaTime() + delay
            transform.fillMode = .backwards
            transform.timingFunction = timing
            layer.add(transform, forKey: "transform")
        }
    }

    // MARK: - Helpers

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func setTransitionRasterizationEnabled(_ enabled: Bool, scale: CGFloat) {
        rasterizationResetTask?.cancel()
        let rasterizationScale = max(scale, 1)
        let layers = [containerView.layer, hostingView?.layer].compactMap { $0 }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            layer.shouldRasterize = enabled
            layer.rasterizationScale = rasterizationScale
        }
        CATransaction.commit()
    }

    private func scheduleRasterizationReset(after delay: CFTimeInterval) {
        rasterizationResetTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let scale = self.activeGeometry?.screen.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            self.setTransitionRasterizationEnabled(false, scale: scale)
        }
        rasterizationResetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func resolveGeometry() -> NotchGeometry? {
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        return NotchGeometry.resolve(preferredScreen: mouseScreen)
    }

    private func panelFrame(for geometry: NotchGeometry) -> NSRect {
        let frame = geometry.screen.frame
        let size = panelSize(for: geometry)
        let originY = geometry.topY - size.height
        return NSRect(x: frame.minX, y: originY, width: size.width, height: size.height)
    }

    private func panelSize(for geometry: NotchGeometry) -> CGSize {
        CGSize(width: geometry.screen.frame.width, height: Self.panelHeight)
    }

    private func finishHide() {
        isHiding = false
        activeGeometry = nil
        let scale = panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        setTransitionRasterizationEnabled(false, scale: scale)
        panel.orderOut(nil)
        store.dedupeSweep()
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
