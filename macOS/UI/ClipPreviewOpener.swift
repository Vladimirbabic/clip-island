import AppKit
import Foundation

@MainActor
enum ClipPreviewOpener {
    static func open(_ item: ClipItem) {
        switch item.kind {
        case .url:
            if let text = item.text, let url = URL(string: text) {
                NSWorkspace.shared.open(url)
            }
        case .text:
            if let url = writeTemporaryText(item) {
                NSWorkspace.shared.open(url)
            }
        case .image:
            if let url = writeTemporaryData(
                item.imageData,
                preferredName: previewFileName(for: item, fileExtension: "png")
            ) {
                NSWorkspace.shared.open(url)
            }
        case .file:
            if let url = firstExistingFileURL(for: item) ?? writeStoredFile(item) {
                NSWorkspace.shared.open(url)
            } else if let url = writeTemporaryData(
                item.imageData,
                preferredName: previewFileName(for: item, fileExtension: "png")
            ) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    static func canOpen(_ item: ClipItem) -> Bool {
        switch item.kind {
        case .text:
            return !(item.text ?? "").isEmpty
        case .url:
            return URL(string: item.text ?? "") != nil
        case .image:
            return item.imageData != nil
        case .file:
            return firstExistingFileURL(for: item) != nil || item.fileData != nil || item.imageData != nil
        }
    }

    private static func writeTemporaryText(_ item: ClipItem) -> URL? {
        writeTemporaryData(
            (item.text ?? "").data(using: .utf8),
            preferredName: previewFileName(for: item, fileExtension: "txt")
        )
    }

    private static func writeStoredFile(_ item: ClipItem) -> URL? {
        guard let data = item.fileData else { return nil }
        return writeTemporaryData(data, preferredName: sanitized(item.fileName ?? "ClipStory File"))
    }

    private static func writeTemporaryData(_ data: Data?, preferredName: String) -> URL? {
        guard let data else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClipStoryPreviews", isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(sanitized(preferredName))
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func firstExistingFileURL(for item: ClipItem) -> URL? {
        let paths = (item.text ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        return paths.lazy
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func previewFileName(for item: ClipItem, fileExtension pathExtension: String) -> String {
        let base = item.customTitle ?? item.fileName ?? item.kind.displayName
        return "\(sanitized(base))-\(item.dedupID.uuidString.prefix(8)).\(pathExtension)"
    }

    private static func sanitized(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "ClipStory Preview" : cleaned
    }
}
