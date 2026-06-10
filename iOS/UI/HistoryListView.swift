import SwiftData
import SwiftUI

/// Root screen: searchable, sectioned clipboard history synced via iCloud,
/// with a pinboard chip row switching the list between History and boards.
struct HistoryListView: View {
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var syncStatus: CloudSyncStatus
    @Query(sort: \ClipItem.createdAt, order: .reverse) private var items: [ClipItem]
    @Query(sort: [
        SortDescriptor(\Pinboard.sortOrder),
        SortDescriptor(\Pinboard.createdAt),
    ]) private var pinboards: [Pinboard]

    @State private var searchText = ""
    @State private var selectedBoardID: PersistentIdentifier?
    @State private var isShowingClearConfirmation = false
    @State private var isShowingSettings = false

    @State private var newBoardItem: ClipItem?
    @State private var newBoardName = ""

    @State private var copyFeedback: CopyFeedback?
    @State private var copyFeedbackDismissal: Task<Void, Never>?

    private var selectedBoard: Pinboard? {
        pinboards.first { $0.persistentModelID == selectedBoardID }
    }

    /// History = items on no board (filtered in-memory; relationship-nil
    /// #Predicate support has OS-version quirks). A board tab = its items.
    private var scopedItems: [ClipItem] {
        guard let board = selectedBoard else {
            return items.filter { $0.pinboard == nil }
        }
        return items.filter { $0.pinboard?.persistentModelID == board.persistentModelID }
    }

    private var filteredItems: [ClipItem] {
        ClipSearch.filter(items: scopedItems, query: searchText)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !pinboards.isEmpty {
                    PinboardChipsRow(pinboards: pinboards, selectedBoardID: $selectedBoardID)
                }
                content
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search clips")
            .toolbar { toolbarContent }
            .confirmationDialog(
                "Clear Unpinned History?",
                isPresented: $isShowingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear Unpinned History", role: .destructive) {
                    store.clearUnpinned()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Pinned items and pinboard items are kept. This cannot be undone.")
            }
            .alert("New Pinboard", isPresented: isNewBoardAlertPresented) {
                TextField("Name", text: $newBoardName)
                Button("Create") { commitNewBoard() }
                Button("Cancel", role: .cancel) { newBoardItem = nil }
            } message: {
                Text("The clip is added to the new pinboard.")
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsSheet()
            }
            .overlay(alignment: .bottom) {
                if let copyFeedback {
                    FeedbackBanner(text: copyFeedback.text, systemImage: copyFeedback.systemImage)
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if filteredItems.isEmpty {
            if !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else if let board = selectedBoard {
                emptyBoardState(for: board)
            } else {
                emptyState
            }
        } else {
            clipList
        }
    }

    private var clipList: some View {
        List {
            if selectedBoard == nil {
                let pinned = filteredItems.filter(\.isPinned)
                let history = filteredItems.filter { !$0.isPinned }

                if !pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(pinned) { row(for: $0) }
                    }
                }
                if !history.isEmpty {
                    Section("History") {
                        ForEach(history) { row(for: $0) }
                    }
                }
            } else {
                Section {
                    ForEach(filteredItems) { row(for: $0) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(for item: ClipItem) -> some View {
        NavigationLink {
            ClipDetailView(item: item)
        } label: {
            ClipRowView(item: item)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                store.togglePin(item)
            } label: {
                Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.delete(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                showCopyFeedback(success: ClipboardWriter.copy(item))
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                store.togglePin(item)
            } label: {
                Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
            }
            AddToPinboardMenu(item: item, pinboards: pinboards) {
                newBoardName = ""
                newBoardItem = item
            }
            Button(role: .destructive) {
                store.delete(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text("ClipStory")
                .font(.headline)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            SaveClipboardButton()
            overflowMenu
        }
    }

    private var overflowMenu: some View {
        Menu {
            Section {
                Button {
                    isShowingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Button(role: .destructive) {
                    isShowingClearConfirmation = true
                } label: {
                    Label("Clear Unpinned History…", systemImage: "trash")
                }
            }
            Section {
                // Status row only; rendered disabled on purpose.
                Button {} label: {
                    Label(syncStatus.statusText, systemImage: syncStatus.state.systemImageName)
                }
                .disabled(true)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More options")
    }

    // MARK: - Empty states

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Clips Yet", systemImage: "doc.on.clipboard")
        } description: {
            Text("Items you copy on your Mac appear here automatically via iCloud, and pinboards keep favorites organized. Tap + to save whatever is on your iPhone clipboard right now.")
        }
    }

    private func emptyBoardState(for board: Pinboard) -> some View {
        ContentUnavailableView {
            Label("Nothing on \(board.displayName)", systemImage: "square.grid.2x2")
        } description: {
            Text("Add clips to this pinboard from a clip's context menu or its detail view.")
        }
    }

    // MARK: - Actions

    private var isNewBoardAlertPresented: Binding<Bool> {
        Binding(
            get: { newBoardItem != nil },
            set: { if !$0 { newBoardItem = nil } }
        )
    }

    private func commitNewBoard() {
        guard let item = newBoardItem else { return }
        newBoardItem = nil
        let trimmed = newBoardName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let board = store.createPinboard(named: trimmed.isEmpty ? "Untitled" : trimmed) else {
            return
        }
        store.assign(item, to: board)
    }

    private func showCopyFeedback(success: Bool) {
        copyFeedbackDismissal?.cancel()
        withAnimation { copyFeedback = CopyFeedback(success: success) }
        copyFeedbackDismissal = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation { copyFeedback = nil }
        }
    }
}
