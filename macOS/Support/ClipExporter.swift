import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum ClipExporter {
    static func exportJSON(items: [ClipItem], pinboards: [Pinboard]) {
        let panel = NSSavePanel()
        panel.title = "Export ClipStory JSON"
        panel.nameFieldStringValue = "clipstory-export.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let pageNames = Dictionary(
            uniqueKeysWithValues: pinboards.map { ($0.persistentModelID, $0.displayName) }
        )
        let payload = ClipStoryExport(
            exportedAt: Date(),
            clips: items.map { item in
                ClipExportRecord(
                    id: item.dedupID.uuidString,
                    createdAt: item.createdAt,
                    kind: item.kind.rawValue,
                    title: item.customTitle,
                    text: item.text,
                    recognizedText: item.recognizedText,
                    fileName: item.fileName,
                    sourceAppName: item.sourceAppName,
                    sourceAppBundleID: item.sourceAppBundleID,
                    isPinned: item.isPinned,
                    pageName: item.pinboard.flatMap { pageNames[$0.persistentModelID] }
                )
            }
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(payload).write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

private struct ClipStoryExport: Encodable {
    let exportedAt: Date
    let clips: [ClipExportRecord]
}

private struct ClipExportRecord: Encodable {
    let id: String
    let createdAt: Date
    let kind: String
    let title: String?
    let text: String?
    let recognizedText: String?
    let fileName: String?
    let sourceAppName: String?
    let sourceAppBundleID: String?
    let isPinned: Bool
    let pageName: String?
}
