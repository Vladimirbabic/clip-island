import AppKit

extension Notification.Name {
    /// Posted with the post-`clearContents()` change count in `userInfo`
    /// (key `PasteboardWriter.changeCountKey`) right before ClipStory writes
    /// to the general pasteboard, so the clipboard monitor can skip
    /// re-capturing our own write. Best effort: re-capture of an identical
    /// item is harmless because insert de-duplicates.
    static let clipStoryOwnPasteboardWrite = Notification.Name("clipstory.ownPasteboardWrite")
}

/// The single place that knows how to write a `ClipItem`'s flavors to a
/// pasteboard. Used by the panel's context-menu Copy; `PasteService` should
/// adopt it too so the write logic cannot drift.
@MainActor
enum PasteboardWriter {
    static let changeCountKey = "changeCount"

    static func write(item: ClipItem, to pasteboard: NSPasteboard = .general) {
        let changeCount = pasteboard.clearContents()
        NotificationCenter.default.post(
            name: .clipStoryOwnPasteboardWrite,
            object: nil,
            userInfo: [changeCountKey: changeCount]
        )

        switch item.kind {
        case .text, .url:
            pasteboard.setString(item.text ?? "", forType: .string)
        case .image:
            writeImage(item, to: pasteboard)
        case .file:
            writeFile(item, to: pasteboard)
        }
    }

    private static func writeImage(_ item: ClipItem, to pasteboard: NSPasteboard) {
        guard let data = item.imageData else { return }
        pasteboard.setData(data, forType: .png)
        if let tiff = NSImage(data: data)?.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    private static func writeFile(_ item: ClipItem, to pasteboard: NSPasteboard) {
        let paths = (item.text ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let existingURLs = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) as NSURL }

        if !existingURLs.isEmpty {
            pasteboard.writeObjects(existingURLs)
        } else if let url = materializedFileURL(for: item) {
            pasteboard.writeObjects([url as NSURL])
        } else if let path = item.text, !path.isEmpty {
            // The file is gone (or lives on another device); the path string
            // still makes the paste useful.
            pasteboard.setString(path, forType: .string)
        }
    }

    private static func materializedFileURL(for item: ClipItem) -> URL? {
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
}
