import AppKit
import OSLog
import SwiftUI

/// Ownership graph (kept deliberately flat):
/// - `AppEnvironment.shared` owns the persistence stack (`PersistenceSetup`),
///   `ClipStore`, and `CloudSyncStatus`, shared with the SwiftUI `Settings`
///   scene declared in `ClipStoryApp`.
/// - `AppDelegate` owns the `NSStatusItem`, `ClipboardMonitor`,
///   `PasteService`, `LinkMetadataService`, `PanelController`, and the global
///   `HotKey`.
/// - `PasteService` references `ClipboardMonitor` so it can mark our own
///   pasteboard writes before the monitor polls them.
/// - `PanelController` references `PasteService` for the paste-back flow.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.vladbabic.clipstory", category: "app")

    private var statusItem: NSStatusItem?
    private var monitor: ClipboardMonitor?
    private var pasteService: PasteService?
    private var linkMetadataService: LinkMetadataService?
    private var panelController: PanelController?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment.shared
        let arguments = ProcessInfo.processInfo.arguments

        let monitor = ClipboardMonitor(store: environment.store)
        let pasteService = PasteService(monitor: monitor)
        let linkMetadataService = LinkMetadataService(store: environment.store)
        let panelController = PanelController(
            store: environment.store,
            container: environment.container,
            syncStatus: environment.syncStatus,
            pasteService: pasteService
        )
        self.monitor = monitor
        self.pasteService = pasteService
        self.linkMetadataService = linkMetadataService
        self.panelController = panelController

        monitor.onItemCaptured = { [weak self] item in
            guard item.kind == .url else { return }
            self?.linkMetadataService?.fetchMetadata(for: item)
        }

        // The mode check keeps demo data out of the real store if the
        // in-memory container could not be created.
        if arguments.contains("--demo-data"), environment.persistence.mode == .inMemory {
            DemoDataSeeder.seed(into: environment.store)
        }

        configureStatusItem()
        monitor.start()

        hotKey = HotKey { [weak self] in
            self?.panelController?.toggle()
        }
        if hotKey == nil {
            logger.error("Failed to register the global \u{21E7}\u{2318}V hotkey")
        }

        if arguments.contains("--show-panel") {
            // Defer one runloop turn so launch (status item, panel layout)
            // fully settles before the panel animates in.
            DispatchQueue.main.async { [weak self] in
                self?.panelController?.show()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Status item

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: "ClipStory"
            )
            button.toolTip = "ClipStory — clipboard history (\u{21E7}\u{2318}V)"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = statusItem
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            panelController?.toggle()
        }
    }

    /// Temporarily attaching the menu and re-clicking is the supported way to
    /// show a menu for one click only while keeping plain left-click actions.
    private func showStatusMenu() {
        guard let statusItem else { return }
        statusItem.menu = makeStatusMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: "Open ClipStory",
            action: #selector(togglePanelFromMenu),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let isPaused = UserDefaults.standard.bool(forKey: AppConstants.capturePausedKey)
        let pauseItem = NSMenuItem(
            title: isPaused ? "Resume Capture" : "Pause Capture",
            action: #selector(toggleCapturePaused),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit ClipStory",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Menu actions

    @objc private func togglePanelFromMenu() {
        panelController?.toggle()
    }

    @objc private func toggleCapturePaused() {
        let defaults = UserDefaults.standard
        let isPaused = defaults.bool(forKey: AppConstants.capturePausedKey)
        defaults.set(!isPaused, forKey: AppConstants.capturePausedKey)
    }

    @objc private func openSettingsFromMenu() {
        panelController?.hide()
        SettingsOpener.open()
    }
}

/// Opens the SwiftUI `Settings` scene from AppKit code.
///
/// The private `showSettingsWindow:` responder selector no longer exists on
/// macOS 15, so a transient borderless window hosts an invisible SwiftUI view
/// just long enough to capture the `openSettings` environment action and call
/// it; the helper window is then closed.
@MainActor
enum SettingsOpener {
    private static var helperWindow: NSWindow?

    static func open() {
        // LSUIElement app: activate first so the Settings window comes forward.
        NSApp.activate(ignoringOtherApps: true)
        guard helperWindow == nil else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: SettingsOpenerView {
            closeHelperWindow()
        })
        helperWindow = window
        window.orderFrontRegardless()
    }

    private static func closeHelperWindow() {
        helperWindow?.orderOut(nil)
        helperWindow?.contentView = nil
        helperWindow = nil
    }
}

/// Invisible view that exists only to capture `openSettings` and invoke it.
private struct SettingsOpenerView: View {
    @Environment(\.openSettings) private var openSettings
    let onDone: () -> Void

    var body: some View {
        Color.clear
            .onAppear {
                openSettings()
                // Tear the helper window down on the next runloop turn, after
                // the action has been delivered.
                DispatchQueue.main.async {
                    onDone()
                }
            }
    }
}
