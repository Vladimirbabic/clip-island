import UIKit

/// Writes a history item back onto the system pasteboard.
@MainActor
enum ClipboardWriter {
    /// Returns false when the item had nothing usable to write. Successful
    /// writes record the resulting pasteboard `changeCount` so auto-import
    /// skips our own copies (see `IOSSettingsKeys.lastImportedChangeCount`).
    @discardableResult
    static func copy(_ item: ClipItem) -> Bool {
        let pasteboard = UIPasteboard.general
        let didWrite: Bool

        switch item.kind {
        case .text:
            didWrite = write(text: item.text, to: pasteboard)
        case .url:
            if let text = item.text, let url = URL(string: text) {
                pasteboard.url = url
                didWrite = true
            } else {
                didWrite = write(text: item.text, to: pasteboard)
            }
        case .image:
            if let data = item.imageData, let image = UIImage(data: data) {
                pasteboard.image = image
                didWrite = true
            } else {
                didWrite = false
            }
        case .file:
            // File contents never sync; the name is the best we can offer.
            didWrite = write(text: item.fileName, to: pasteboard)
        }

        if didWrite {
            UserDefaults.standard.set(
                pasteboard.changeCount, forKey: IOSSettingsKeys.lastImportedChangeCount
            )
        }
        return didWrite
    }

    private static func write(text: String?, to pasteboard: UIPasteboard) -> Bool {
        guard let text, !text.isEmpty else { return false }
        pasteboard.string = text
        return true
    }
}
