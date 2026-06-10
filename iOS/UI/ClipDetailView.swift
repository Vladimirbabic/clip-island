import SwiftData
import SwiftUI
import UIKit

/// Full-screen view of one clip: complete content, metadata, and copy /
/// pin / pinboard / delete actions. Decoding the full image here is fine —
/// only list rows must use downsampled thumbnails.
struct ClipDetailView: View {
    @EnvironmentObject private var store: ClipStore
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [
        SortDescriptor(\Pinboard.sortOrder),
        SortDescriptor(\Pinboard.createdAt),
    ]) private var pinboards: [Pinboard]

    let item: ClipItem

    @State private var copyFeedback: CopyFeedback?
    @State private var copyFeedbackDismissal: Task<Void, Never>?
    @State private var isShowingNewBoardAlert = false
    @State private var newBoardName = ""
    @State private var isShowingRenameSheet = false
    @State private var renameText = ""
    @State private var isShowingTextEditSheet = false
    @State private var editText = ""

    var body: some View {
        List {
            Section("Content") {
                contentView
            }
            if let recognizedText = item.recognizedText,
               !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Recognized Text") {
                    Text(recognizedText)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
            Section("Details") {
                metadataRows
            }
        }
        .navigationTitle(item.kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: copyToClipboard) {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy")

                Button {
                    store.togglePin(item)
                } label: {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                }
                .accessibilityLabel(item.isPinned ? "Unpin" : "Pin")

                pinboardMenu

                editMenu

                Button(role: .destructive) {
                    store.delete(item)
                    dismiss()
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete")
            }
        }
        .alert("New Page", isPresented: $isShowingNewBoardAlert) {
            TextField("Name", text: $newBoardName)
            Button("Create") { commitNewBoard() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The clip is saved to the new page.")
        }
        .sheet(isPresented: $isShowingRenameSheet) {
            TextEditSheet(title: "Rename Clip", text: $renameText, actionTitle: "Save") {
                store.rename(item, to: renameText)
            }
        }
        .sheet(isPresented: $isShowingTextEditSheet) {
            TextEditSheet(title: "Edit Text", text: $editText, actionTitle: "Save") {
                store.updateText(item, to: editText)
            }
        }
        .overlay(alignment: .bottom) {
            if let copyFeedback {
                FeedbackBanner(text: copyFeedback.text, systemImage: copyFeedback.systemImage)
            }
        }
    }

    private var pinboardMenu: some View {
        Menu {
            AddToPinboardMenu(item: item, pinboards: pinboards) {
                newBoardName = ""
                isShowingNewBoardAlert = true
            }
        } label: {
            Image(systemName: item.pinboard?.iconName ?? "square.grid.2x2")
        }
        .accessibilityLabel("Page")
    }

    private var editMenu: some View {
        Menu {
            Button {
                renameText = item.customTitle ?? item.preview
                isShowingRenameSheet = true
            } label: {
                Label("Rename", systemImage: "text.cursor")
            }
            if item.kind == .text || item.kind == .url {
                Button {
                    editText = item.text ?? ""
                    isShowingTextEditSheet = true
                } label: {
                    Label("Edit Text", systemImage: "square.and.pencil")
                }
            }
            if item.imageData != nil {
                Button {
                    rotateImagePreview()
                } label: {
                    Label("Rotate Image", systemImage: "rotate.right")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Edit")
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        switch item.kind {
        case .text:
            Text(item.text ?? "")
                .font(.body)
                .textSelection(.enabled)
        case .url:
            urlContent
        case .image:
            if let data = item.imageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
            } else {
                Label("Image unavailable", systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
        case .file:
            if let data = item.imageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
            }
            Label(item.fileName ?? "File", systemImage: item.kind.systemImageName)
                .font(.body)
            Text(fileDetailMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var fileDetailMessage: String {
        if item.fileData != nil {
            return "Saved file contents. This item is protected from clearing unsaved clipboard history."
        }
        if item.imageData != nil {
            return "A preview image synced from the Mac. The original file remains on the Mac where it was captured."
        }
        return "File contents stay on the Mac where this clip was captured. Only the file reference syncs to this device."
    }

    /// Links with macOS-fetched metadata lead with preview image and title;
    /// plain URL text otherwise.
    @ViewBuilder
    private var urlContent: some View {
        let hasTitle = !(item.linkTitle ?? "").isEmpty

        if let data = item.imageData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
        }
        if let title = item.linkTitle, hasTitle {
            Text(title)
                .font(.headline)
                .textSelection(.enabled)
        }
        Text(item.text ?? "")
            .font(hasTitle ? .subheadline : .body)
            .foregroundStyle(hasTitle ? Color.secondary : Color.primary)
            .textSelection(.enabled)
        if let text = item.text, let url = URL(string: text) {
            Link(destination: url) {
                Label("Open Link", systemImage: "safari")
            }
        }
    }

    @ViewBuilder
    private var metadataRows: some View {
        LabeledContent("Kind", value: item.kind.displayName)
        if let source = item.sourceAppName, !source.isEmpty {
            LabeledContent("Source", value: source)
        }
        if let board = item.pinboard {
            LabeledContent("Page", value: board.displayName)
        }
        if let title = item.customTitle, !title.isEmpty {
            LabeledContent("Title", value: title)
        }
        LabeledContent("Date", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
        if item.kind == .text, let text = item.text {
            LabeledContent("Characters", value: "\(text.count)")
        }
    }

    // MARK: - Actions

    private func copyToClipboard() {
        let success = ClipboardWriter.copy(item)
        copyFeedbackDismissal?.cancel()
        withAnimation { copyFeedback = CopyFeedback(success: success) }
        copyFeedbackDismissal = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation { copyFeedback = nil }
        }
    }

    private func commitNewBoard() {
        let trimmed = newBoardName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let board = store.createPinboard(named: trimmed.isEmpty ? "Untitled" : trimmed) else {
            return
        }
        store.assign(item, to: board)
    }

    private func rotateImagePreview() {
        guard let imageData = item.imageData else { return }
        let store = store
        let contentHash = item.contentHash
        Task.detached(priority: .userInitiated) {
            guard let rotated = Self.rotatedPNGDataClockwise(from: imageData) else { return }
            let recognizedText = ImageTextRecognizer.recognizedText(in: rotated)
            await MainActor.run {
                // Re-find by hash in case SwiftData refreshed the model while
                // the pixel work was running.
                if item.contentHash == contentHash {
                    store.updateImageData(item, imageData: rotated, recognizedText: recognizedText)
                }
            }
        }
    }

    private static func rotatedPNGDataClockwise(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let rotatedSize = CGSize(width: size.height, height: size.width)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: rotatedSize, format: format)
        let rotated = renderer.image { context in
            context.cgContext.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
            context.cgContext.rotate(by: .pi / 2)
            image.draw(in: CGRect(
                x: -size.width / 2,
                y: -size.height / 2,
                width: size.width,
                height: size.height
            ))
        }
        return rotated.pngData()
    }
}

private struct TextEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var text: String
    let actionTitle: String
    let onCommit: () -> Void

    init(title: String, text: Binding<String>, actionTitle: String, onCommit: @escaping () -> Void) {
        self.title = title
        _text = text
        self.actionTitle = actionTitle
        self.onCommit = onCommit
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .background(Color.black)
                .foregroundStyle(.white)
                .padding()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(actionTitle) {
                            onCommit()
                            dismiss()
                        }
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}
