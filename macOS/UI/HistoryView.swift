import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Root content of the bottom history panel: a centered search control +
/// pinboard tab strip on top (with an overflow menu trailing), and a
/// horizontal strip of clip cards below, newest first.
@MainActor
struct HistoryView: View {
    @ObservedObject private var store: ClipStore
    @ObservedObject private var syncStatus: CloudSyncStatus
    private let onCheckForUpdates: () -> Void
    private let onPaste: (ClipItem) -> Void
    private let onClose: () -> Void

    @Query(sort: \ClipItem.createdAt, order: .reverse) private var items: [ClipItem]
    @Query(sort: [SortDescriptor(\Pinboard.sortOrder), SortDescriptor(\Pinboard.createdAt)])
    private var pinboards: [Pinboard]

    @AppStorage(AppConstants.capturePausedKey) private var isCapturePaused = false
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var isSearchExpanded = false
    @State private var selectedKindFilter: ClipKind?
    @State private var selectedSourceFilter: String?
    @State private var selectedDateFilter: ClipDateFilter = .any
    @State private var savedOnlyFilter = false
    @State private var pinnedOnlyFilter = false
    @State private var recognizedTextOnlyFilter = false
    @State private var selectedTab: PanelTab = .history
    @State private var selectedIndex = 0
    @State private var wheelAccumulator: CGFloat = 0
    @State private var isShowingClearConfirmation = false
    @State private var isShowingManualNoteSheet = false
    @State private var renamingItem: ClipItem?
    @State private var renameText = ""
    @State private var editingTextItem: ClipItem?
    @State private var editText = ""
    @State private var manualAddErrorMessage = ""
    @State private var isShowingManualAddError = false
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isGridFocused: Bool

    private static let topBarLeadingWidth: CGFloat = 118
    private static let topBarTrailingWidth: CGFloat = 98
    private static let cardPadding: CGFloat = 16
    private static let cardSpacing: CGFloat = 12
    private static let wheelStepThreshold: CGFloat = 42
    private static var cardStripHeight: CGFloat {
        ClipCardView.cardSize.height + cardPadding * 2
    }

    init(
        store: ClipStore,
        syncStatus: CloudSyncStatus,
        onCheckForUpdates: @escaping () -> Void,
        onPaste: @escaping (ClipItem) -> Void,
        onClose: @escaping () -> Void
    ) {
        _store = ObservedObject(wrappedValue: store)
        _syncStatus = ObservedObject(wrappedValue: syncStatus)
        self.onCheckForUpdates = onCheckForUpdates
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
        ClipSearch.filter(items: tabItems, query: query, filters: searchFilters)
    }

    private var searchFilters: ClipSearchFilters {
        ClipSearchFilters(
            kind: selectedKindFilter,
            sourceAppName: selectedSourceFilter,
            date: selectedDateFilter,
            savedOnly: savedOnlyFilter,
            pinnedOnly: pinnedOnlyFilter,
            withRecognizedTextOnly: recognizedTextOnlyFilter
        )
    }

    private var sourceAppNames: [String] {
        Array(Set(items.compactMap { item in
            let value = item.sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }))
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
        .onChange(of: searchFilters) { _, _ in selectedIndex = 0 }
        .onChange(of: selectedTab) { _, _ in
            selectedIndex = 0
            isSearchFocused = false
            focusGrid()
        }
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
        .sheet(isPresented: $isShowingManualNoteSheet) {
            ManualNoteSheet { text in
                addManualNote(text)
            }
        }
        .sheet(isPresented: isRenameSheetPresented) {
            ClipTextSheet(title: "Rename Clip", text: $renameText, actionTitle: "Save") {
                guard let item = renamingItem else { return }
                store.rename(item, to: renameText)
                renamingItem = nil
            }
        }
        .sheet(isPresented: isTextEditSheetPresented) {
            ClipTextSheet(title: "Edit Text", text: $editText, actionTitle: "Save") {
                guard let item = editingTextItem else { return }
                store.updateText(item, to: editText)
                editingTextItem = nil
            }
        }
        .alert("Could Not Add Item", isPresented: $isShowingManualAddError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(manualAddErrorMessage)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            syncChip
            .frame(width: Self.topBarLeadingWidth, alignment: .leading)
            HStack(spacing: 10) {
                searchControl
                filterControl
                ScrollView(.horizontal, showsIndicators: false) {
                    PinboardTabStrip(pinboards: pinboards, selection: $selectedTab)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            HStack(spacing: 8) {
                updateButton
                addMenu
                overflowMenu
            }
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
                    .onKeyPress(phases: [.down, .repeat]) { handleSearchKey($0) }
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

    private var filterControl: some View {
        Menu {
            Picker("Kind", selection: kindFilterBinding) {
                Text("Any Kind").tag(String?.none)
                ForEach(ClipKind.allCases, id: \.rawValue) { kind in
                    Text(kind.displayName).tag(Optional(kind.rawValue))
                }
            }
            if !sourceAppNames.isEmpty {
                Picker("Source", selection: $selectedSourceFilter) {
                    Text("Any Source").tag(String?.none)
                    ForEach(sourceAppNames, id: \.self) { source in
                        Text(source).tag(Optional(source))
                    }
                }
            }
            Picker("Date", selection: $selectedDateFilter) {
                ForEach(ClipDateFilter.allCases, id: \.rawValue) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            Toggle("Saved Only", isOn: $savedOnlyFilter)
            Toggle("Pinned Only", isOn: $pinnedOnlyFilter)
            Toggle("OCR Text Only", isOn: $recognizedTextOnlyFilter)
            if searchFilters.isActive {
                Divider()
                Button("Clear Filters") { clearFilters() }
            }
        } label: {
            Image(systemName: searchFilters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(searchFilters.isActive ? .blue : .white.opacity(0.65))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Search filters")
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
        Group {
            Button("") { _ = pasteSelected() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(visibleItems.isEmpty)
            ForEach(1...9, id: \.self) { number in
                Button("") { if visibleItems.indices.contains(number - 1) { onPaste(visibleItems[number - 1]) } }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .disabled(!canUseGlobalPasteShortcuts)
        .accessibilityHidden(true)
    }

    private var canUseGlobalPasteShortcuts: Bool {
        !isShowingClearConfirmation
            && !isShowingManualNoteSheet
            && !isShowingManualAddError
            && renamingItem == nil
            && editingTextItem == nil
    }

    private var addMenu: some View {
        Menu {
            Button("New Note\u{2026}") { isShowingManualNoteSheet = true }
            Button("Add File\u{2026}") { chooseManualFile() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add saved item")
    }

    private var updateButton: some View {
        Button {
            onCheckForUpdates()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Check for updates")
    }

    private var overflowMenu: some View {
        Menu {
            Button(isCapturePaused ? "Resume Capture" : "Pause Capture") { isCapturePaused.toggle() }
            Button("Check for Updates\u{2026}") { onCheckForUpdates() }
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
                    .background {
                        HorizontalWheelScrollMonitor { delta in
                            handleWheelScroll(delta)
                        }
                    }
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
        .onKeyPress(phases: [.down, .repeat]) { handleGridKey($0) }
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
            focusGrid()
            onPaste(item)
        }
        .onTapGesture {
            selectedIndex = index
            focusGrid()
        }
        .contextMenu { contextMenu(for: item) }
    }

    @ViewBuilder
    private func contextMenu(for item: ClipItem) -> some View {
        Button("Paste") { onPaste(item) }
        Button("Copy") { PasteboardWriter.write(item: item) }
        if ClipPreviewOpener.canOpen(item) {
            Button("Preview") { ClipPreviewOpener.open(item) }
        }
        Button("Rename\u{2026}") {
            renameText = item.customTitle ?? item.preview
            renamingItem = item
        }
        if item.kind == .text || item.kind == .url {
            Button("Edit Text\u{2026}") {
                editText = item.text ?? ""
                editingTextItem = item
            }
        }
        Divider()
        Menu("Add to Page") {
            ForEach(pinboards, id: \.persistentModelID) { board in
                Button {
                    store.assign(item, to: board)
                } label: {
                    Label(board.displayName, systemImage: board.iconName)
                }
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
            return (selectedBoard.iconName, "\(selectedBoard.displayName) is empty",
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

    private var kindFilterBinding: Binding<String?> {
        Binding(
            get: { selectedKindFilter?.rawValue },
            set: { selectedKindFilter = $0.flatMap(ClipKind.init(rawValue:)) }
        )
    }

    private var isRenameSheetPresented: Binding<Bool> {
        Binding(
            get: { renamingItem != nil },
            set: { if !$0 { renamingItem = nil } }
        )
    }

    private var isTextEditSheetPresented: Binding<Bool> {
        Binding(
            get: { editingTextItem != nil },
            set: { if !$0 { editingTextItem = nil } }
        )
    }

    private func clearFilters() {
        selectedKindFilter = nil
        selectedSourceFilter = nil
        selectedDateFilter = .any
        savedOnlyFilter = false
        pinnedOnlyFilter = false
        recognizedTextOnlyFilter = false
    }

    private func focusGrid() {
        DispatchQueue.main.async {
            isSearchFocused = false
            isGridFocused = false
            DispatchQueue.main.async {
                isGridFocused = true
            }
        }
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
        isSearchFocused = false
        focusGrid()
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

    private func handleWheelScroll(_ delta: CGFloat) {
        guard !visibleItems.isEmpty else { return }
        wheelAccumulator += delta
        while abs(wheelAccumulator) >= Self.wheelStepThreshold {
            let step = wheelAccumulator > 0 ? 1 : -1
            _ = moveSelection(by: step)
            wheelAccumulator -= CGFloat(step) * Self.wheelStepThreshold
        }
    }

    private func pasteSelected() -> KeyPress.Result {
        guard visibleItems.indices.contains(selectedIndex) else { return .ignored }
        onPaste(visibleItems[selectedIndex])
        return .handled
    }

    private func addManualNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showManualAddError("Write something before saving the note.")
            return
        }
        let content = CapturedContent(
            kind: .text,
            text: trimmed,
            sourceAppName: "ClipStory",
            sourceAppBundleID: Bundle.main.bundleIdentifier
        )
        guard store.insertManual(content, to: selectedBoard) != nil else {
            showManualAddError("The note could not be saved.")
            return
        }
    }

    private func chooseManualFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"

        if panel.runModal() == .OK, let url = panel.url {
            addManualFile(from: url)
        }
    }

    private func addManualFile(from url: URL) {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            if let fileSize = values.fileSize, fileSize > AppConstants.maxManualFileByteCount {
                showManualAddError(maxFileSizeMessage)
                return
            }
            let data = try Data(contentsOf: url)
            guard data.count <= AppConstants.maxManualFileByteCount else {
                showManualAddError(maxFileSizeMessage)
                return
            }
            let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
            let isImage = type?.conforms(to: .image) == true
            let content = CapturedContent(
                kind: .file,
                text: url.path(percentEncoded: false),
                imageData: isImage ? data : nil,
                fileData: data,
                fileName: url.lastPathComponent,
                fileTypeIdentifier: type?.identifier ?? "public.data",
                sourceAppName: "ClipStory",
                sourceAppBundleID: Bundle.main.bundleIdentifier
            )
            guard store.insertManual(content, to: selectedBoard) != nil else {
                showManualAddError("The file could not be saved.")
                return
            }
        } catch {
            showManualAddError(error.localizedDescription)
        }
    }

    private var maxFileSizeMessage: String {
        "Files larger than \(ByteCountFormatter.string(fromByteCount: Int64(AppConstants.maxManualFileByteCount), countStyle: .file)) cannot be saved yet."
    }

    private func showManualAddError(_ message: String) {
        manualAddErrorMessage = message
        isShowingManualAddError = true
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
        wheelAccumulator = 0
        validateSelectedTab()
        focusGrid()
    }
}

private struct ManualNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    let onSave: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 440, height: 260)
                .padding(12)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 464)
    }
}

private struct ClipTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var text: String
    let actionTitle: String
    let onCommit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 440, height: 230)
                .padding(12)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(actionTitle) {
                    onCommit()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 464)
    }
}

private struct HorizontalWheelScrollMonitor: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> WheelMonitorView {
        let view = WheelMonitorView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: WheelMonitorView, context: Context) {
        nsView.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: WheelMonitorView, coordinator: ()) {
        nsView.uninstall()
    }

    final class WheelMonitorView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                uninstall()
            } else {
                install()
            }
        }

        deinit {
            uninstall()
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point), window.isKeyWindow else { return event }

                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard !flags.contains(.command) else { return event }

                let horizontal = event.scrollingDeltaX
                let vertical = event.scrollingDeltaY
                let rawDelta = abs(horizontal) > abs(vertical) ? horizontal : -vertical
                guard rawDelta != 0 else { return event }

                let normalizedDelta = event.hasPreciseScrollingDeltas ? rawDelta : rawDelta * 24
                self.onScroll?(normalizedDelta)
                return nil
            }
        }
    }
}
