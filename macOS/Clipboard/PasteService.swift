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
    private static let pasteDelay: TimeInterval = 0.25
    private static let activationPollInterval: TimeInterval = 0.04
    private static let maxActivationAttempts = 18
    private nonisolated static let vKeyCode: CGKeyCode = 9

    private let monitor: ClipboardMonitor

    init(monitor: ClipboardMonitor) {
        self.monitor = monitor
    }

    struct PasteTarget {
        let app: NSRunningApplication

        static func capture(app: NSRunningApplication?) -> PasteTarget? {
            guard let app, !app.isTerminated else { return nil }
            return PasteTarget(app: app)
        }
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

    /// Copies the item, force re-activates the app that was active before the
    /// panel opened, and synthesizes ⌘V. Without Accessibility permission the
    /// item is only copied.
    func paste(item: ClipItem, into target: PasteTarget?) {
        copy(item: item)
        guard Self.isAccessibilityTrusted else { return }

        guard let target, !target.app.isTerminated else {
            postCommandVAfterPasteDelay()
            return
        }

        activate(target.app)
        waitForActivation(of: target, attempt: 0)
    }

    private func waitForActivation(of target: PasteTarget, attempt: Int) {
        let app = target.app
        if isActivePasteTarget(app) || attempt >= Self.maxActivationAttempts {
            postCommandVAfterPasteDelay()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.activationPollInterval) { [weak self] in
            Task { @MainActor in
                self?.activate(app)
                self?.waitForActivation(of: target, attempt: attempt + 1)
            }
        }
    }

    private func activate(_ app: NSRunningApplication) {
        guard !app.isTerminated else { return }
        app.unhide()
        app.activate()
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    private func isActivePasteTarget(_ app: NSRunningApplication) -> Bool {
        app.isActive
            || NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private func postCommandVAfterPasteDelay() {
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
            writeImageFlavors(pngData, to: pasteboard)
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

        if !existingURLs.isEmpty {
            pasteboard.writeObjects(existingURLs)
            if let pngData = item.imageData, isImageFileClip(item) {
                writeImageFlavors(pngData, to: pasteboard)
            }
            return
        }
        if let pngData = item.imageData, isImageFileClip(item) {
            writeImageFlavors(pngData, to: pasteboard)
            return
        }
        if let url = materializedFileURL(for: item) {
            pasteboard.writeObjects([url as NSURL])
            return
        }
        NSSound.beep()
    }

    private func materializedFileURL(for item: ClipItem) -> URL? {
        guard let data = item.fileData, let fileName = item.fileName, !fileName.isEmpty else {
            return nil
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipStoryFiles", isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(fileName)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func writeImageFlavors(_ pngData: Data, to pasteboard: NSPasteboard) {
        pasteboard.setData(pngData, forType: .png)
        if let tiffData = NSImage(data: pngData)?.tiffRepresentation {
            pasteboard.setData(tiffData, forType: .tiff)
        }
    }

    private func isImageFileClip(_ item: ClipItem) -> Bool {
        guard item.kind == .file else { return false }
        if let fileName = item.fileName, Self.isPreviewableImagePath(fileName) {
            return true
        }
        return (item.text ?? "")
            .split(separator: "\n")
            .contains { Self.isPreviewableImagePath(String($0)) }
    }

    private static func isPreviewableImagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "heic", "webp", "tif", "tiff", "gif", "bmp"]
            .contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private nonisolated static func postCommandV() {
        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
