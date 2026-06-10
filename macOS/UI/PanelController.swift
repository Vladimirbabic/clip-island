import AppKit
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

/// Owns the Paste-style bottom panel: full width of the screen with the mouse,
/// anchored to the bottom edge, slide-up + fade animation.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private static let panelHeight: CGFloat = 340
    private static let animationDuration: TimeInterval = 0.18
    private static let slideDistance: CGFloat = 24

    private let panel: HistoryPanel
    private let store: ClipStore
    private let pasteService: PasteService
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
            contentRect: .zero,
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

        let finalFrame = targetFrame()
        if !panel.isVisible {
            panel.setFrame(finalFrame.offsetBy(dx: 0, dy: -Self.slideDistance), display: false)
            panel.alphaValue = 0
        }
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .clipStoryPanelDidShow, object: nil)
        }
    }

    func hide() {
        guard panel.isVisible, !isHiding else { return }
        isHiding = true

        let endFrame = panel.frame.offsetBy(dx: 0, dy: -Self.slideDistance)
        NSAnimationContext.runAnimationGroup({ [weak self] context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self?.panel.animator().alphaValue = 0
            self?.panel.animator().setFrame(endFrame, display: true)
        }, completionHandler: { [weak self] in
            // NSAnimationContext completions run on the main thread.
            MainActor.assumeIsolated {
                guard let self, self.isHiding else { return }
                self.isHiding = false
                self.panel.orderOut(nil)
            }
        })
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: - Setup

    private func configurePanel() {
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
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
            onPaste: { [weak self] item in
                self?.paste(item)
            },
            onClose: { [weak self] in
                self?.hide()
            }
        )
        .modelContainer(container)
        .environmentObject(store)

        panel.contentView = NSHostingView(rootView: rootView)
    }

    // MARK: - Helpers

    private func paste(_ item: ClipItem) {
        let target = pasteTarget
        isHiding = false
        // Order out synchronously (no hide animation) so the panel has fully
        // resigned key before the synthesized ⌘V fires — otherwise the paste
        // lands in our own search field. The re-entrant windowDidResignKey ->
        // hide() call is a no-op because `panel.isVisible` is already false
        // after orderOut.
        panel.orderOut(nil)
        pasteService.paste(item: item, into: target)
    }

    /// Full width of the screen the mouse is on, anchored to the bottom of the
    /// visible frame (above the Dock).
    private func targetFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen else {
            return NSRect(x: 0, y: 0, width: 800, height: Self.panelHeight)
        }
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.minX,
            y: visible.minY,
            width: visible.width,
            height: Self.panelHeight
        )
    }
}
