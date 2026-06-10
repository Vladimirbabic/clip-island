import AppKit
import ApplicationServices
import Foundation

/// Writes clips back to the general pasteboard and (with Accessibility
/// permission) synthesizes ⌘V into the previously frontmost app.
@MainActor
final class PasteService {
    /// Focus-settling margin between re-activating the target app and posting
    /// the synthesized ⌘V. The panel has already been ordered out synchronously
    /// by `PanelController` before this delay starts.
    private static let pasteDelay: TimeInterval = 0.15
    private nonisolated static let vKeyCode: CGKeyCode = 9

    private let monitor: ClipboardMonitor

    init(monitor: ClipboardMonitor) {
        self.monitor = monitor
    }

    // MARK: - Accessibility

    nonisolated static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    nonisolated static func requestAccessibilityAccess() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    // MARK: - Pasteboard

    func copy(item: ClipItem) {
        let pasteboard = NSPasteboard.general
        // clearContents() returns the new change count; handing it to the
        // monitor as the FIRST write step means this write is acknowledged
        // (change counts stay in sync) but never re-captured.
        monitor.noteOwnWrite(changeCount: pasteboard.clearContents())

        switch item.kind {
        case .text, .image:
            writeAllFlavors(item, to: pasteboard)
        case .url:
            // imageData on URL items is fetched link-preview metadata, not an
            // original pasteboard flavor — write only the URL string.
            if let text = item.text, !text.isEmpty {
                pasteboard.setString(text, forType: .string)
            }
        case .file:
            writeFile(item, to: pasteboard)
        }
    }

    /// Copies the item, re-activates the app that was frontmost before the
    /// panel opened, and synthesizes ⌘V. Without Accessibility permission the
    /// item is only copied.
    func paste(item: ClipItem, into previousApp: NSRunningApplication?) {
        copy(item: item)
        guard Self.isAccessibilityTrusted else { return }

        previousApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteDelay) {
            Self.postCommandV()
        }
    }

    // MARK: - Private

    /// Writes EVERY stored flavor (string + png/tiff) so target apps pick
    /// their preferred representation (e.g. spreadsheet cells carry both a
    /// text table and a rendered image).
    private func writeAllFlavors(_ item: ClipItem, to pasteboard: NSPasteboard) {
        if let text = item.text, !text.isEmpty {
            pasteboard.setString(text, forType: .string)
        }
        if let pngData = item.imageData {
            pasteboard.setData(pngData, forType: .png)
            if let tiffData = NSImage(data: pngData)?.tiffRepresentation {
                pasteboard.setData(tiffData, forType: .tiff)
            }
        }
    }

    /// Re-materializes file URLs for the stored paths (one per line) that
    /// still exist on disk. If every file is gone, writes NOTHING and beeps —
    /// never silently pastes a stale absolute path as text.
    private func writeFile(_ item: ClipItem, to pasteboard: NSPasteboard) {
        let paths = (item.text ?? "")
            .split(separator: "\n")
            .map(String.init)
        let existingURLs = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) as NSURL }

        guard !existingURLs.isEmpty else {
            NSSound.beep()
            return
        }
        pasteboard.writeObjects(existingURLs)
    }

    private nonisolated static func postCommandV() {
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
