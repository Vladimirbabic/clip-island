import AppKit
import SwiftData
import SwiftUI

/// Root content of the bottom history panel: a centered search control +
/// pinboard tab strip on top (with an overflow menu trailing), and a
/// horizontal strip of clip cards below, newest first.
@MainActor
struct HistoryView: View {
    @ObservedObject private var store: ClipStore
    @ObservedObject private var syncStatus: CloudSyncStatus
    private let onPaste: (ClipItem) -> Void
    private let onClose: () -> Void

    @Query(sort: \ClipItem.createdAt, order: .reverse) private var items: [ClipItem]
    @Query(sort: [SortDescriptor(\Pinboard.sortOrder), SortDescriptor(\Pinboard.createdAt)])
    private var pinboards: [Pinboard]

    @AppStorage(AppConstants.capturePausedKey) private var isCapturePaused = false
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var isSearchExpanded = false
    @State private var selectedTab: PanelTab = .history
    @State private var selectedIndex = 0
    @State private var isShowingClearConfirmation = false
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isGridFocused: Bool

    private static let topBarLeadingWidth: CGFloat = 118
    private static let topBarTrailingWidth: CGFloat = 26
    private static let cardPadding: CGFloat = 16
    private static let cardSpacing: CGFloat = 12
    private static var cardStripHeight: CGFloat {
        ClipCardView.cardSize.height + cardPadding * 2
    }

    init(
        store: ClipStore,
        syncStatus: CloudSyncStatus,
        onPaste: @escaping (ClipItem) -> Void,
        onClose: @escaping () -> Void
    ) {
        _store = ObservedObject(wrappedValue: store)
        _syncStatus = ObservedObject(wrappedValue: syncStatus)
        self.onPaste = onPaste
        self.onClose = onClose
    }

    // MARK: - Filtering

    /// History shows every clip. Page tabs are additional saved views; saving
    /// a clip to a page must not make it disappear from the main history.
    private var tabItems: [ClipItem] {
        switch selectedTab {
        case .history:
            return items
        case .board(let id):
            return items.filter { $0.pinboard?.persistentModelID == id }
        }
    }

    private var visibleItems: [ClipItem] {
        ClipSearch.filter(items: tabItems, query: query)
    }

    private var visibleItemIDs: [PersistentIdentifier] {
        visibleItems.map(\.persistentModelID)
    }

    private var pinboardIDs: [PersistentIdentifier] {
        pinboards.map(\.persistentModelID)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.35)
            cardArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The panel container paints the solid black notch backdrop and owns
        // the rounded-bottom bloom shape; keep the content itself transparent.
        .background(Color.clear)
        .background(quickPasteShortcuts)
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onChange(of: selectedTab) { _, _ in selectedIndex = 0 }
        .onChange(of: visibleItemIDs) { _, _ in clampSelection() }
        .onChange(of: pinboardIDs) { _, _ in validateSelectedTab() }
        .onAppear { focusGrid() }
        .onReceive(
            NotificationCenter.default.publisher(for: Notification.Name("clipStoryPanelDidShow"))
        ) { _ in resetForPresentation() }
        .alert("Clear unsaved history?", isPresented: $isShowingClearConfirmation) {
            Button("Clear Unsaved History", role: .destructive) { store.clearUnpinned() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pinned clips and clips saved to pages are kept. This cannot be undone.")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            syncChip
                .frame(width: Self.topBarLeadingWidth, alignment: .leading)
            HStack(spacing: 10) {
                searchControl
                ScrollView(.horizontal, showsIndicators: false) {
                    PinboardTabStrip(pinboards: pinboards, selection: $selectedTab)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            overflowMenu
                .frame(width: Self.topBarTrailingWidth, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    @ViewBuilder
    private var searchControl: some View {
        if isSearchExpanded {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(width: 170)
                    .focused($isSearchFocused)
                    .onSubmit { _ = pasteSelected() }
                    .onKeyPress(.escape) { collapseSearch(); return .handled }
                    .onKeyPress(.leftArrow) { moveSelection(by: -1) }
                    .onKeyPress(.rightArrow) { moveSelection(by: 1) }
                    .onKeyPress(.upArrow) { switchTab(by: -1) }
                    .onKeyPress(.downArrow) { switchTab(by: 1) }
                    .onKeyPress(phases: .down) { handleSearchKey($0) }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.white.opacity(0.1), in: Capsule())
        } else {
            Button { expandSearch(initialText: "") } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search clips (or just start typing)")
        }
    }

    @ViewBuilder
    private var syncChip: some View {
        HStack(spacing: 5) {
            Image(systemName: syncSymbolName).font(.system(size: 10.5, weight: .semibold))
            Text(syncChipText).font(.system(size: 11))
        }
        .foregroundStyle(syncChipColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.08), in: Capsule())
        .fixedSize()
        .help(syncStatus.statusText)
    }

    private var syncChipText: String {
        switch syncStatus.state {
        case .syncing: return "iCloud On"
        case .noAccount: return "No account"
        case .localOnly: return "Local only"
        case .ephemeral: return "Not saved"
        }
    }

    private var syncSymbolName: String {
        switch syncStatus.state {
        case .syncing: return "checkmark.icloud"
        case .noAccount: return "icloud.slash"
        case .localOnly: return "xmark.icloud"
        case .ephemeral: return "exclamationmark.icloud"
        }
    }

    private var syncChipColor: Color {
        switch syncStatus.state {
        case .syncing: return .green
        case .noAccount: return .orange
        case .localOnly: return .white.opacity(0.6)
        case .ephemeral: return .red
        }
    }

    /// Hidden buttons so ⌘1…⌘9 paste the Nth visible card even while the
    /// search field has focus (keyboard shortcuts resolve window-wide).
    private var quickPasteShortcuts: some View {
        ForEach(1...9, id: \.self) { number in
            Button("") { if visibleItems.indices.contains(number - 1) { onPaste(visibleItems[number - 1]) } }
                .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var overflowMenu: some View {
        Menu {
            Button(isCapturePaused ? "Resume Capture" : "Pause Capture") { isCapturePaused.toggle() }
            Button("Clear Unsaved History\u{2026}") { isShowingClearConfirmation = true }
            Divider()
            Button("Settings\u{2026}") {
                onClose()
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Divider()
            Button("Quit ClipStory") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    // MARK: - Cards

    private var cardArea: some View {
        Group {
            if visibleItems.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: Self.cardSpacing) {
                            ForEach(
                                Array(visibleItems.enumerated()),
                                id: \.element.persistentModelID
                            ) { index, item in
                                card(for: item, at: index)
                            }
                        }
                        .padding(Self.cardPadding)
                    }
                    .frame(height: Self.cardStripHeight, alignment: .top)
                    .onChange(of: selectedIndex) { _, newIndex in
                        guard visibleItems.indices.contains(newIndex) else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(visibleItems[newIndex].persistentModelID, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($isGridFocused)
        .onKeyPress(phases: .down) { handleGridKey($0) }
    }

    private func card(for item: ClipItem, at index: Int) -> some View {
        ClipCardView(
            item: item,
            isSelected: index == selectedIndex,
            quickPasteIndex: index < 9 ? index : nil
        )
        .id(item.persistentModelID)
        .onTapGesture(count: 2) {
            selectedIndex = index
            onPaste(item)
        }
        .onTapGesture {
            selectedIndex = index
        }
        .contextMenu { contextMenu(for: item) }
    }

    @ViewBuilder
    private func contextMenu(for item: ClipItem) -> some View {
        Button("Paste") { onPaste(item) }
        Button("Copy") { PasteboardWriter.write(item: item) }
        Divider()
        Menu("Add to Page") {
            ForEach(pinboards, id: \.persistentModelID) { board in
                Button(board.displayName) { store.assign(item, to: board) }
                    .disabled(item.pinboard?.persistentModelID == board.persistentModelID)
            }
            if !pinboards.isEmpty {
                Divider()
            }
            Button("New Page\u{2026}") {
                if let board = store.createPinboard(named: "Untitled") { store.assign(item, to: board) }
            }
        }
        if item.pinboard != nil {
            Button("Remove from Page") { store.assign(item, to: nil) }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(item) }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: emptyContent.symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white.opacity(0.25))
            Text(emptyContent.title)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.85))
            Text(emptyContent.hint)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedBoard: Pinboard? {
        guard case .board(let id) = selectedTab else { return nil }
        return pinboards.first { $0.persistentModelID == id }
    }

    private var emptyContent: (symbol: String, title: String, hint: String) {
        if !query.isEmpty {
            return ("magnifyingglass", "No clips match \u{201C}\(query)\u{201D}", "Try a different search.")
        }
        if let selectedBoard {
            return ("square.grid.2x2", "\(selectedBoard.displayName) is empty",
                    "Right-click any clip to save it to this page.")
        }
        return ("doc.on.clipboard", "Copy something to get started",
                "Press \u{21E7}\u{2318}V anytime to open ClipStory.")
    }

    // MARK: - Search expansion & keyboard

    private func expandSearch(initialText: String) {
        isSearchExpanded = true
        query = initialText
        // The field only exists on the next render pass; focus it then.
        DispatchQueue.main.async { isSearchFocused = true }
    }

    private func collapseSearch() {
        query = ""
        isSearchExpanded = false
        isSearchFocused = false
        focusGrid()
    }

    private func focusGrid() {
        DispatchQueue.main.async { isGridFocused = true }
    }

    private func handleEscape() -> KeyPress.Result {
        if isSearchExpanded { collapseSearch() } else { onClose() }
        return .handled
    }

    /// Single dispatcher for the card grid: Tab / Shift-Tab and Up/Down switch
    /// the tab group up top, Left/Right move card selection, Return pastes the
    /// selected clip, Escape closes, and any printable key opens search.
    private func handleGridKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .tab:
            return switchTab(by: press.modifiers.contains(.shift) ? -1 : 1)
        case .upArrow:
            return switchTab(by: -1)
        case .downArrow:
            return switchTab(by: 1)
        case .leftArrow:
            return moveSelection(by: -1)
        case .rightArrow:
            return moveSelection(by: 1)
        case .return:
            return pasteSelected()
        case .escape:
            return handleEscape()
        default:
            return handleTyping(press)
        }
    }

    private func handleSearchKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .tab {
            return switchTab(by: press.modifiers.contains(.shift) ? -1 : 1)
        }
        return .ignored
    }

    /// Cycles the selected tab (Clipboard History + each pinboard) with wrap.
    private func switchTab(by delta: Int) -> KeyPress.Result {
        let tabs: [PanelTab] = [.history] + pinboards.map { PanelTab.board($0.persistentModelID) }
        guard tabs.count > 1 else { return .handled }
        let current = tabs.firstIndex(of: selectedTab) ?? 0
        let next = ((current + delta) % tabs.count + tabs.count) % tabs.count
        selectedTab = tabs[next]
        return .handled
    }

    private static let typingExcludedKeys: [KeyEquivalent] = [
        .escape, .return, .tab, .space, .upArrow, .downArrow, .leftArrow, .rightArrow,
        .delete, .deleteForward, .home, .end, .pageUp, .pageDown, .clear,
    ]

    /// Typing any printable character while browsing expands the search
    /// field and seeds it with that character.
    private func handleTyping(_ press: KeyPress) -> KeyPress.Result {
        guard !isSearchExpanded else { return .ignored }
        guard !press.modifiers.contains(.command), !press.modifiers.contains(.control) else {
            return .ignored
        }
        guard !Self.typingExcludedKeys.contains(press.key) else { return .ignored }
        let scalars = press.characters.unicodeScalars
        let isPrintable = !scalars.isEmpty && !scalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || (0xF700...0xF8FF).contains(scalar.value) // function-key range
        }
        guard isPrintable else { return .ignored }
        expandSearch(initialText: press.characters)
        return .handled
    }

    // MARK: - Selection

    private func moveSelection(by delta: Int) -> KeyPress.Result {
        let count = visibleItems.count
        guard count > 0 else { return .ignored }
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
        return .handled
    }

    private func pasteSelected() -> KeyPress.Result {
        guard visibleItems.indices.contains(selectedIndex) else { return .ignored }
        onPaste(visibleItems[selectedIndex])
        return .handled
    }

    private func clampSelection() {
        selectedIndex = max(0, min(selectedIndex, visibleItems.count - 1))
    }

    private func validateSelectedTab() {
        if case .board(let id) = selectedTab, !pinboardIDs.contains(id) {
            selectedTab = .history
        }
    }

    private func resetForPresentation() {
        query = ""
        isSearchExpanded = false
        isSearchFocused = false
        selectedIndex = 0
        validateSelectedTab()
        focusGrid()
    }
}
