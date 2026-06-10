import SwiftData
import SwiftUI
import UIKit

/// Root screen: searchable clipboard history synced via iCloud, with saved
/// pages available from the bottom picker.
struct HistoryListView: View {
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var syncStatus: CloudSyncStatus
    @Query(sort: \ClipItem.createdAt, order: .reverse) private var items: [ClipItem]
    @Query(sort: [
        SortDescriptor(\Pinboard.sortOrder),
        SortDescriptor(\Pinboard.createdAt),
    ]) private var pinboards: [Pinboard]

    @State private var searchText = ""
    @State private var isSearchVisible = false
    @State private var selectedBoardID: PersistentIdentifier?
    @State private var isShowingClearConfirmation = false
    @State private var isShowingSettings = false
    @State private var isSelecting = false
    @State private var selectedItemIDs = Set<PersistentIdentifier>()

    @State private var newBoardItem: ClipItem?
    @State private var newBoardName = ""
    @State private var isShowingNewPageAlert = false
    @State private var newPageName = ""

    @State private var copyFeedback: CopyFeedback?
    @State private var copyFeedbackDismissal: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool

    private let gridColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    private var selectedBoard: Pinboard? {
        pinboards.first { $0.persistentModelID == selectedBoardID }
    }

    /// History shows every clip. Pages are saved views, not folders that move
    /// clips out of the main history.
    private var scopedItems: [ClipItem] {
        guard let board = selectedBoard else {
            return items
        }
        return items.filter { $0.pinboard?.persistentModelID == board.persistentModelID }
    }

    private var filteredItems: [ClipItem] {
        ClipSearch.filter(items: scopedItems, query: searchText)
    }

    private var filteredItemIDs: [PersistentIdentifier] {
        filteredItems.map(\.persistentModelID)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar
                    if isSearchVisible {
                        searchBar
                    }
                    content
                }
                bottomBar
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .confirmationDialog(
                "Clear Unsaved History?",
                isPresented: $isShowingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear Unsaved History", role: .destructive) {
                    store.clearUnpinned()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Pinned clips and clips saved to pages are kept. This cannot be undone.")
            }
            .alert("New Page", isPresented: isNewBoardAlertPresented) {
                TextField("Name", text: $newBoardName)
                Button("Create") { commitNewBoard() }
                Button("Cancel", role: .cancel) { newBoardItem = nil }
            } message: {
                Text("The clip is saved to the new page.")
            }
            .alert("New Page", isPresented: $isShowingNewPageAlert) {
                TextField("Name", text: $newPageName)
                Button("Create") { createEmptyPage() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Create a saved page for clips you want to keep.")
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsSheet()
            }
            .overlay(alignment: .bottom) {
                if let copyFeedback {
                    FeedbackBanner(text: copyFeedback.text, systemImage: copyFeedback.systemImage)
                        .padding(.bottom, 74)
                }
            }
            .onChange(of: filteredItemIDs) { _, ids in
                selectedItemIDs.formIntersection(Set(ids))
                if ids.isEmpty {
                    selectedItemIDs.removeAll()
                }
            }
        }
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedBoard?.displayName ?? "Clipboard History")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(syncStatus.statusText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button(isSelecting ? "Done" : "Select") {
                isSelecting.toggle()
                if !isSelecting {
                    selectedItemIDs.removeAll()
                }
            }
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 46)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            overflowMenu
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.6))
            TextField("Search clips", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isSearchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.body)
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
        .onAppear { isSearchFocused = true }
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
                    Label("Clear Unsaved History...", systemImage: "trash")
                }
            }
            Section {
                Button {} label: {
                    Label(syncStatus.statusText, systemImage: syncStatus.state.systemImageName)
                }
                .disabled(true)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Color.white.opacity(0.08), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .accessibilityLabel("More options")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if filteredItems.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(filteredItems) { item in
                        cardContainer(for: item)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 112)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func cardContainer(for item: ClipItem) -> some View {
        if isSelecting {
            Button {
                toggleSelection(for: item)
            } label: {
                ClipGridCardView(item: item, isSelected: selectedItemIDs.contains(item.persistentModelID))
            }
            .buttonStyle(.plain)
            .contextMenu { cardMenu(for: item) }
        } else {
            NavigationLink {
                ClipDetailView(item: item)
            } label: {
                ClipGridCardView(item: item, isSelected: false)
            }
            .buttonStyle(.plain)
            .contextMenu { cardMenu(for: item) }
        }
    }

    @ViewBuilder
    private func cardMenu(for item: ClipItem) -> some View {
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

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: emptyContent.symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text(emptyContent.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
                .multilineTextAlignment(.center)
            Text(emptyContent.hint)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.48))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 88)
    }

    private var emptyContent: (symbol: String, title: String, hint: String) {
        if !searchText.isEmpty {
            return ("magnifyingglass", "No clips match \"\(searchText)\"", "Try a different search.")
        }
        if let selectedBoard {
            return ("square.grid.2x2", "\(selectedBoard.displayName) is empty",
                    "Tap + to save the current clipboard here, or add clips from their menu.")
        }
        return ("doc.on.clipboard", "No Clips Yet",
                "Copy on your Mac or tap + to save the current iPhone clipboard.")
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private var bottomBar: some View {
        if isSelecting {
            selectionBar
        } else {
            mainBottomBar
        }
    }

    private var mainBottomBar: some View {
        HStack(spacing: 18) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    isSearchVisible.toggle()
                    if !isSearchVisible {
                        searchText = ""
                        isSearchFocused = false
                    }
                }
            } label: {
                Image(systemName: isSearchVisible ? "xmark" : "magnifyingglass")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(Color.white.opacity(0.08), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSearchVisible ? "Close search" : "Search")

            pagePicker

            SaveClipboardButton(targetPinboard: selectedBoard, isCircular: true)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var pagePicker: some View {
        Menu {
            Button {
                selectedBoardID = nil
            } label: {
                Label("Clipboard History", systemImage: selectedBoard == nil ? "checkmark" : "clock.arrow.circlepath")
            }
            ForEach(pinboards) { board in
                Button {
                    selectedBoardID = board.persistentModelID
                } label: {
                    Label(board.displayName, systemImage: selectedBoardID == board.persistentModelID ? "checkmark" : "square.grid.2x2")
                }
            }
            Divider()
            Button {
                newPageName = ""
                isShowingNewPageAlert = true
            } label: {
                Label("New Page...", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(selectedBoard.map { PinboardColor.color(named: $0.colorName) } ?? Color(red: 0.78, green: 0.22, blue: 0.88))
                    .frame(width: 14, height: 14)
                Text(selectedBoard?.displayName ?? "Clipboard History")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .padding(.horizontal, 18)
            .background(Color.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .accessibilityLabel("Choose page")
    }

    private var selectionBar: some View {
        HStack(spacing: 14) {
            Button("Cancel") {
                isSelecting = false
                selectedItemIDs.removeAll()
            }
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(height: 52)
            .padding(.horizontal, 16)
            .background(Color.white.opacity(0.08), in: Capsule())

            Text("\(selectedItemIDs.count) selected")
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity)

            Button(role: .destructive) {
                deleteSelection()
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.red.opacity(selectedItemIDs.isEmpty ? 0.18 : 0.28), in: Circle())
            }
            .disabled(selectedItemIDs.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    // MARK: - Actions

    private var isNewBoardAlertPresented: Binding<Bool> {
        Binding(
            get: { newBoardItem != nil },
            set: { if !$0 { newBoardItem = nil } }
        )
    }

    private func toggleSelection(for item: ClipItem) {
        let id = item.persistentModelID
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
        }
    }

    private func deleteSelection() {
        let selected = Set(selectedItemIDs)
        for item in filteredItems where selected.contains(item.persistentModelID) {
            store.delete(item)
        }
        selectedItemIDs.removeAll()
        isSelecting = false
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

    private func createEmptyPage() {
        let trimmed = newPageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let board = store.createPinboard(named: trimmed.isEmpty ? "Untitled" : trimmed) else {
            return
        }
        selectedBoardID = board.persistentModelID
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

private struct ClipGridCardView: View {
    let item: ClipItem
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Circle()
                    .fill(accentColor)
                    .frame(width: 13, height: 13)
            }

            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .frame(height: 196, alignment: .topLeading)
        .background(Color(red: 0.10, green: 0.10, blue: 0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(11)
            }
        }
        .overlay(alignment: .center) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.white, Color.accentColor)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var title: String {
        if let board = item.pinboard {
            return board.displayName
        }
        return item.kind.displayName
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .text:
            Text(item.preview)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(6)
                .multilineTextAlignment(.leading)
        case .url:
            urlPreview
        case .image:
            imagePreview
        case .file:
            filePreview
        }
    }

    @ViewBuilder
    private var urlPreview: some View {
        if let thumbnail = ClipThumbnailLoader.thumbnail(for: item) {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Text(item.linkTitle ?? item.text ?? "")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(5)
            }
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let thumbnail = ClipThumbnailLoader.thumbnail(for: item) {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            centeredIcon("photo")
        }
    }

    private var filePreview: some View {
        VStack(spacing: 10) {
            Image(systemName: item.kind.systemImageName)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.55))
            Text(item.fileName ?? item.preview)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centeredIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 34, weight: .light))
            .foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accentColor: Color {
        if let board = item.pinboard {
            return PinboardColor.color(named: board.colorName)
        }
        if item.isPinned {
            return .orange
        }
        switch item.kind {
        case .text: return Color(red: 0.78, green: 0.22, blue: 0.88)
        case .url: return .indigo
        case .image: return .green
        case .file: return .gray
        }
    }
}
