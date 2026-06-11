import AppKit
import QuartzCore
import SwiftData
import SwiftUI

extension Notification.Name {
    /// Posted every time the history panel is presented so the SwiftUI content
    /// can reset search state.
    static let clipStoryPanelDidShow = Notification.Name("clipStoryPanelDidShow")
    /// Posted by the panel-level event tap while the island is visible. The panel
    /// is intentionally not key, so SwiftUI key focus is not involved.
    static let clipStoryPanelKeyPressed = Notification.Name("clipStoryPanelKeyPressed")
    /// Posted by SwiftUI when secondary UI needs normal key focus, such as
    /// sheets. The paste-first island path keeps this off.
    static let clipStoryPanelKeyboardCaptureChanged = Notification.Name("clipStoryPanelKeyboardCaptureChanged")
}

/// Borderless, non-activating panel. In the normal paste path it is shown
/// without becoming key so the previously active app keeps its cursor.
private final class HistoryPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onReturn: (() -> Void)?
    var allowsKeyFocus = false

    override var canBecomeKey: Bool { allowsKeyFocus }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func sendEvent(_ event: NSEvent) {
        if shouldHandleReturn(event) {
            onReturn?()
            return
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape, when no responder consumed it
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    private func shouldHandleReturn(_ event: NSEvent) -> Bool {
        guard attachedSheet == nil, event.type == .keyDown else { return false }
        guard event.keyCode == 36 || event.keyCode == 76 else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.isDisjoint(with: [.command, .control, .option])
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
    private static let openDuration: CFTimeInterval = 0.34
    private static let closeDuration: CFTimeInterval = 0.22
    private static let contentFadeInDuration: CFTimeInterval = 0.24
    private static let contentFadeOutDuration: CFTimeInterval = 0.11
    private static let contentEntranceOffset: CGFloat = 12
    private static let openTiming = CAMediaTimingFunction(controlPoints: 0.18, 0.92, 0.20, 1.00)
    private static let closeTiming = CAMediaTimingFunction(controlPoints: 0.55, 0.00, 0.90, 0.60)
    private static let fadeTiming = CAMediaTimingFunction(controlPoints: 0.25, 0.85, 0.25, 1.00)
    private static let contentTiming = CAMediaTimingFunction(controlPoints: 0.16, 1.00, 0.30, 1.00)

    private let panel: HistoryPanel
    private let store: ClipStore
    private let pasteService: PasteService
    private let onCheckForUpdates: () -> Void
    private let keyboardEventTap = PanelKeyboardEventTap()

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

    /// App that was active when the panel was last shown.
    private var pasteTarget: PasteService.PasteTarget?
    private var activeAppObserver: NSObjectProtocol?
    private var keyboardCaptureObserver: NSObjectProtocol?
    private var keyboardCapturePaused = false
    private var isHiding = false
    /// Global mouse-down monitor active while the panel is shown; a click in
    /// any other app dismisses the island. Global monitors never see clicks
    /// on our own windows, so the island (and our alerts) are exempt.
    private var outsideClickMonitor: Any?

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
        observeKeyboardCaptureRequests()
        installContent(store: store, container: container, syncStatus: syncStatus)
    }

    deinit {
        if let activeAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeAppObserver)
        }
        if let keyboardCaptureObserver {
            NotificationCenter.default.removeObserver(keyboardCaptureObserver)
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        keyboardEventTap.stop()
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
        maskLayer.removeAllAnimations()
        hostingView?.layer?.removeAllAnimations()
        applyMask(rect: bloom.notch, cornerRadius: Self.cornerRadiusNotch, animated: false)
        setContentVisible(false, animated: false)
        prepareHiddenContentForPresentation()

        keyboardCapturePaused = false
        panel.allowsKeyFocus = false
        panel.orderFrontRegardless()
        startKeyboardCapture()
        startOutsideClickMonitor()

        if reduceMotion {
            applyMask(rect: bloom.full, cornerRadius: Self.cornerRadiusFull, animated: false)
            setContentVisible(true, animated: true, duration: 0.16, delay: 0)
        } else {
            setTransitionRasterizationEnabled(false, scale: geometry.screen.backingScaleFactor)
            applyMask(
                rect: bloom.full,
                cornerRadius: Self.cornerRadiusFull,
                animated: true,
                duration: Self.openDuration,
                timing: Self.openTiming
            )
            setContentVisible(
                true,
                animated: true,
                duration: Self.contentFadeInDuration,
                delay: Self.openDuration * 0.32,
                timing: Self.contentTiming,
                entrance: true
            )
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .clipStoryPanelDidShow, object: nil)
        }
    }

    func hide() {
        guard panel.isVisible, !isHiding else { return }
        isHiding = true
        // Stop swallowing keystrokes the moment the close starts: the
        // typing-forwarding flow replays the dismissing keystroke into the
        // focused app right after onClose(), and it must not be re-captured.
        stopKeyboardCapture()

        guard !reduceMotion, let geometry = activeGeometry else {
            finishHide()
            return
        }

        let bloom = bloomRects(for: geometry)
        setTransitionRasterizationEnabled(false, scale: geometry.screen.backingScaleFactor)
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
        panel.onReturn = {
            NotificationCenter.default.post(name: .clipStoryPanelKeyPressed, object: nil)
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
                guard let self, !self.panel.isVisible, !self.isHiding else { return }
                self.rememberPasteTarget(app)
            }
        }
    }

    private func observeKeyboardCaptureRequests() {
        keyboardCaptureObserver = NotificationCenter.default.addObserver(
            forName: .clipStoryPanelKeyboardCaptureChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let paused = (notification.userInfo?["paused"] as? Bool) ?? false
            Task { @MainActor in
                self?.setKeyboardCapturePaused(paused)
            }
        }
    }

    private func rememberPasteTarget(_ app: NSRunningApplication?) {
        guard let app, isPasteTargetCandidate(app) else { return }
        pasteTarget = PasteService.PasteTarget.capture(app: app)
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
        maskLayer.drawsAsynchronously = true
        maskLayer.allowsEdgeAntialiasing = true
        maskLayer.edgeAntialiasingMask = [
            .layerLeftEdge, .layerRightEdge, .layerBottomEdge, .layerTopEdge,
        ]
        maskLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        containerView.layer?.mask = maskLayer

        hostingView = host
        panel.contentView = containerView
    }

    private func startKeyboardCapture() {
        guard panel.isVisible, !keyboardCapturePaused else { return }
        if keyboardEventTap.start() {
            keyboardEventTap.onKeyDown = { event in
                NotificationCenter.default.post(name: .clipStoryPanelKeyPressed, object: event)
            }
        } else {
            // Fallback for systems where the event tap is unavailable. This keeps
            // keyboard navigation usable, but the normal path above is the one
            // that preserves the target app's cursor.
            panel.allowsKeyFocus = true
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func stopKeyboardCapture() {
        keyboardEventTap.stop()
        keyboardEventTap.onKeyDown = nil
    }

    private func setKeyboardCapturePaused(_ paused: Bool) {
        guard keyboardCapturePaused != paused else { return }
        keyboardCapturePaused = paused
        guard panel.isVisible else { return }
        if paused {
            stopKeyboardCapture()
            panel.allowsKeyFocus = true
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.allowsKeyFocus = false
            panel.orderFrontRegardless()
            startKeyboardCapture()
        }
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
            fromTransform = CATransform3DScale(fromTransform, 0.992, 0.992, 1)
            let transform = CABasicAnimation(keyPath: "transform")
            transform.fromValue = CATransform3DIsIdentity(startTransform) ? fromTransform : startTransform
            transform.toValue = targetTransform
            transform.duration = duration + 0.04
            transform.beginTime = CACurrentMediaTime() + delay
            transform.fillMode = .backwards
            transform.timingFunction = timing
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

    private func prepareHiddenContentForPresentation() {
        hostingView?.layoutSubtreeIfNeeded()
        containerView.displayIfNeeded()
        hostingView?.displayIfNeeded()
    }

    private func setTransitionRasterizationEnabled(_ enabled: Bool, scale: CGFloat) {
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

    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, !self.isHiding else { return }
                // The panel sits above everything in its frame, so any click
                // another app receives is by definition outside the island.
                guard !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.hide()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    private func finishHide() {
        isHiding = false
        activeGeometry = nil
        stopOutsideClickMonitor()
        stopKeyboardCapture()
        keyboardCapturePaused = false
        panel.allowsKeyFocus = false
        let scale = panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        setTransitionRasterizationEnabled(false, scale: scale)
        panel.orderOut(nil)
        store.dedupeSweep()
    }

    private func paste(_ item: ClipItem) {
        let target = pasteTarget
        isHiding = false
        stopKeyboardCapture()
        keyboardCapturePaused = false
        panel.allowsKeyFocus = false
        // Order out synchronously (no animation) so the panel has fully
        // resigned key before the synthesized ⌘V fires — otherwise the paste
        // lands in our own search field.
        panel.orderOut(nil)
        pasteService.paste(item: item, into: target)
    }
}

private final class PanelKeyboardEventTap {
    var onKeyDown: ((NSEvent) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() -> Bool {
        if eventTap != nil { return true }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<PanelKeyboardEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: selfPointer
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown, let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async { [weak self] in
            self?.onKeyDown?(nsEvent)
        }
        return nil
    }
}
