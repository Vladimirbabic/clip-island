import AppIntents
import SwiftData
import UIKit

@available(iOS 17.0, *)
struct SaveClipStoryClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Save Clipboard to ClipStory"
    static var description = IntentDescription("Saves the current clipboard into ClipStory.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let persistence = ModelContainerFactory.makeShared()
        let store = ClipStore(container: persistence.container)
        guard let content = ClipboardReader.readCurrentContent(),
              let item = store.insert(content)
        else {
            return .result(dialog: "Clipboard is empty or unsupported.")
        }
        scheduleOCRUpdate(for: item, store: store)
        return .result(dialog: "Saved to ClipStory.")
    }
}

@available(iOS 17.0, *)
struct CreateClipStoryNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Create ClipStory Note"
    static var description = IntentDescription("Creates a saved ClipStory note that is protected from clearing.")
    static var openAppWhenRun = false

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Title")
    var title: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "Note text is empty.")
        }
        let persistence = ModelContainerFactory.makeShared()
        let store = ClipStore(container: persistence.container)
        let content = CapturedContent(kind: .text, text: trimmed, sourceAppName: "Shortcuts")
        guard store.insertManual(content, title: title) != nil else {
            return .result(dialog: "Could not save the note.")
        }
        return .result(dialog: "Note saved to ClipStory.")
    }
}

@available(iOS 17.0, *)
struct ClipStoryShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveClipStoryClipboardIntent(),
            phrases: [
                "Save clipboard to \(.applicationName)",
                "Add clipboard to \(.applicationName)",
            ],
            shortTitle: "Save Clipboard",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: CreateClipStoryNoteIntent(),
            phrases: [
                "Create note in \(.applicationName)",
                "Save note to \(.applicationName)",
            ],
            shortTitle: "Create Note",
            systemImageName: "square.and.pencil"
        )
    }
}

@MainActor
private func scheduleOCRUpdate(for item: ClipItem, store: ClipStore) {
    guard let imageData = item.imageData else { return }
    let contentHash = item.contentHash
    Task.detached(priority: .utility) {
        let text = ImageTextRecognizer.recognizedText(in: imageData)
        await MainActor.run {
            store.updateRecognizedText(contentHash: contentHash, text: text)
        }
    }
}
