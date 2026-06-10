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

    var body: some View {
        List {
            Section("Content") {
                contentView
            }
            Section("Details") {
                metadataRows
            }
        }
        .navigationTitle(item.kind.displayName)
        .navigationBarTitleDisplayMode(.inline)
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

                Button(role: .destructive) {
                    store.delete(item)
                    dismiss()
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete")
            }
        }
        .alert("New Pinboard", isPresented: $isShowingNewBoardAlert) {
            TextField("Name", text: $newBoardName)
            Button("Create") { commitNewBoard() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The clip is added to the new pinboard.")
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
            Image(systemName: "square.grid.2x2")
        }
        .accessibilityLabel("Pinboard")
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
            Label(item.fileName ?? "File", systemImage: item.kind.systemImageName)
                .font(.body)
            Text("File contents stay on the Mac where this clip was captured. Only the file reference syncs to this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
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
            LabeledContent("Pinboard", value: board.displayName)
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
}
