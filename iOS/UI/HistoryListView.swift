import LocalAuthentication
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Root screen: searchable clipboard history synced via iCloud, with saved
/// pages available from the bottom picker.
struct HistoryListView: View {
    @EnvironmentObject private var store: ClipStore
    @EnvironmentObject private var syncStatus: CloudSyncStatus
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \ClipItem.createdAt, order: .reverse) private var items: [ClipItem]
    @Query(sort: [
        SortDescriptor(\Pinboard.sortOrder),
        SortDescriptor(\Pinboard.createdAt),
    ]) private var pinboards: [Pinboard]

    @State private var searchText = ""
    @State private var isSearchVisible = false
    @State private var selectedKindFilter: ClipKind?
    @State private var selectedSourceFilter: String?
    @State private var selectedDateFilter: ClipDateFilter = .any
    @State private var savedOnlyFilter = false
    @State private var pinnedOnlyFilter = false
    @State private var recognizedTextOnlyFilter = false
    @State private var selectedBoardID: PersistentIdentifier?
    @State private var isShowingClearConfirmation = false
    @State private var isShowingSettings = false
    @State private var isShowingManualNoteSheet = false
    @State private var isShowingFileImporter = false
    @State private var lockSetupBoard: Pinboard?
    @State private var removeLockBoard: Pinboard?
    @State private var unlockedBoardIDs = Set<PersistentIdentifier>()
    @State private var inlineUnlockPassword = ""
    @State private var inlineUnlockError = ""
    @State private var manualAddErrorMessage = ""
    @State private var isShowingManualAddError = false
    @State private var isSelecting = false
    @State private var selectedItemIDs = Set<PersistentIdentifier>()
    @State private var detailPath: [PersistentIdentifier] = []
    @State private var recentlyCopiedItemID: PersistentIdentifier?
    @State private var copiedItemDismissal: Task<Void, Never>?
    @State private var biometricPromptBoardID: PersistentIdentifier?
    @State private var isBiometricUnlockRunning = false

    @State private var newBoardItem: ClipItem?
    @State private var newBoardName = ""
    @State private var isShowingNewPageAlert = false
    @State private var newPageName = ""

    @State private var copyFeedback: CopyFeedback?
    @State private var copyFeedbackDismissal: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isInlineUnlockFocused: Bool

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
            return items.filter { !isHiddenByLockedBoard($0) }
        }
        guard !selectedBoardRequiresUnlock else { return [] }
        return items.filter { $0.pinboard?.persistentModelID == board.persistentModelID }
    }

    private func isHiddenByLockedBoard(_ item: ClipItem) -> Bool {
        guard let board = item.pinboard, board.isLocked else { return false }
        return !unlockedBoardIDs.contains(board.persistentModelID)
    }

    private var filteredItems: [ClipItem] {
        ClipSearch.filter(items: scopedItems, query: searchText, filters: searchFilters)
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

    private var filteredItemIDs: [PersistentIdentifier] {
        filteredItems.map(\.persistentModelID)
    }

    private var selectedBoardRequiresUnlock: Bool {
        guard let board = selectedBoard else { return false }
        return board.isLocked && !unlockedBoardIDs.contains(board.persistentModelID)
    }

    var body: some View {
        NavigationStack(path: $detailPath) {
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar
                    if isSearchVisible {
                        searchBar
                        if searchFilters.isActive {
                            activeFilterStrip
                        }
                    }
                    content
                }
                bottomFade
                bottomBar
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .navigationDestination(for: PersistentIdentifier.self) { itemID in
                if let item = items.first(where: { $0.persistentModelID == itemID }) {
                    ClipDetailView(item: item)
                } else {
                    Text("Clip no longer available")
                        .foregroundStyle(.secondary)
                }
            }
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
            .sheet(isPresented: $isShowingManualNoteSheet) {
                ManualNoteSheet { text in
                    addManualNote(text)
                }
            }
            .sheet(isPresented: isLockSetupPresented) {
                if let lockSetupBoard {
                    PinboardLockSetupSheet(boardName: lockSetupBoard.displayName) { password in
                        if store.lockPinboard(lockSetupBoard, password: password) {
                            unlockedBoardIDs.insert(lockSetupBoard.persistentModelID)
                        }
                        self.lockSetupBoard = nil
                    }
                }
            }
            .sheet(isPresented: isRemoveLockPresented) {
                if let removeLockBoard {
                    PinboardUnlockSheet(
                        boardName: removeLockBoard.displayName,
                        title: "Remove Page Lock",
                        actionTitle: "Remove Lock"
                    ) { password in
                        let didRemove = store.removePinboardLock(removeLockBoard, password: password)
                        if didRemove {
                            unlockedBoardIDs.remove(removeLockBoard.persistentModelID)
                            self.removeLockBoard = nil
                        }
                        return didRemove
                    }
                }
            }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false,
                onCompletion: handleManualFileImport
            )
            .alert("Could Not Add Item", isPresented: $isShowingManualAddError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(manualAddErrorMessage)
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
            .onChange(of: selectedBoardID) { _, _ in
                resetInlineUnlock()
                focusInlineUnlockIfNeeded()
            }
            .onChange(of: selectedBoardRequiresUnlock) { _, _ in
                focusInlineUnlockIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase != .active else { return }
                unlockedBoardIDs.removeAll()
                resetInlineUnlock()
                detailPath.removeAll()
            }
            .onAppear {
                syncStatus.refresh()
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
                if syncStatus.lastCheckedAt != nil {
                    Text(syncStatus.freshnessText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.36))
                        .lineLimit(1)
                }
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
            filterMenu
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

    private var filterMenu: some View {
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
                .foregroundStyle(searchFilters.isActive ? Color.accentColor : Color.white.opacity(0.55))
        }
        .accessibilityLabel("Search filters")
    }

    private var activeFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let selectedKindFilter {
                    filterChip(selectedKindFilter.displayName) { self.selectedKindFilter = nil }
                }
                if let selectedSourceFilter {
                    filterChip(selectedSourceFilter) { self.selectedSourceFilter = nil }
                }
                if selectedDateFilter != .any {
                    filterChip(selectedDateFilter.displayName) { selectedDateFilter = .any }
                }
                if savedOnlyFilter {
                    filterChip("Saved") { savedOnlyFilter = false }
                }
                if pinnedOnlyFilter {
                    filterChip("Pinned") { pinnedOnlyFilter = false }
                }
                if recognizedTextOnlyFilter {
                    filterChip("OCR") { recognizedTextOnlyFilter = false }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
        }
    }

    private func filterChip(_ title: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
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
                Button {
                    refreshSync()
                } label: {
                    Label("Refresh iCloud", systemImage: "arrow.clockwise.icloud")
                }
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
        if selectedBoardRequiresUnlock {
            lockedState
        } else if filteredItems.isEmpty {
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
                .padding(.bottom, 210)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                refreshSync()
            }
        }
    }

    private var lockedState: some View {
        VStack(spacing: 14) {
            Image(systemName: isBiometricUnlockRunning ? "faceid" : "lock.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.36))
            Text("\(selectedBoard?.displayName ?? "Page") is locked")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
                .multilineTextAlignment(.center)
            SecureField("Password", text: $inlineUnlockPassword)
                .textContentType(.password)
                .submitLabel(.go)
                .focused($isInlineUnlockFocused)
                .onSubmit { submitInlineUnlock() }
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(width: 280, height: 48)
                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
            if !inlineUnlockError.isEmpty {
                Text(inlineUnlockError)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.95))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 90)
        .onAppear {
            attemptBiometricUnlockIfAvailable()
            focusInlineUnlockField()
        }
    }

    @ViewBuilder
    private func cardContainer(for item: ClipItem) -> some View {
        if isSelecting {
            Button {
                toggleSelection(for: item)
            } label: {
                ClipGridCardView(
                    item: item,
                    isSelected: selectedItemIDs.contains(item.persistentModelID),
                    isRecentlyCopied: false
                )
            }
            .buttonStyle(.plain)
            .contextMenu { cardMenu(for: item) }
        } else {
            Button {
                copyItem(item)
            } label: {
                ClipGridCardView(
                    item: item,
                    isSelected: false,
                    isRecentlyCopied: recentlyCopiedItemID == item.persistentModelID
                )
            }
            .buttonStyle(.plain)
            .contextMenu { cardMenu(for: item) }
        }
    }

    @ViewBuilder
    private func cardMenu(for item: ClipItem) -> some View {
        Button {
            showDetails(for: item)
        } label: {
            Label("View Details", systemImage: "doc.text.magnifyingglass")
        }
        Button {
            copyItem(item)
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
            return (selectedBoard.iconName, "\(selectedBoard.displayName) is empty",
                    "Tap + to save the current clipboard here, or add clips from their menu.")
        }
        return ("doc.on.clipboard", "No Clips Yet",
                "Copy on your Mac or tap + to save the current iPhone clipboard.")
    }

    // MARK: - Bottom Bar

    private var bottomFade: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.10), location: 0.32),
                    .init(color: .black.opacity(0.70), location: 0.72),
                    .init(color: .black, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 88)
            .frame(maxWidth: .infinity)

            Color.black
                .frame(height: 138)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }

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

            addMenu
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var addMenu: some View {
        Menu {
            Button {
                isShowingManualNoteSheet = true
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
            Button {
                isShowingFileImporter = true
            } label: {
                Label("Add File", systemImage: "doc.badge.plus")
            }
            Divider()
            Button {
                saveCurrentClipboard()
            } label: {
                Label("Save Current Clipboard", systemImage: "doc.on.clipboard")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(Color.white.opacity(0.08), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add")
        .disabled(selectedBoardRequiresUnlock)
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
                    selectBoard(board)
                } label: {
                    Label(
                        board.displayName,
                        systemImage: selectedBoardID == board.persistentModelID
                            ? "checkmark"
                            : (board.isLocked ? "lock.fill" : board.iconName)
                    )
                }
            }
            Divider()
            if let selectedBoard {
                Menu("Page Icon") {
                    ForEach(AppConstants.pinboardIconNames, id: \.self) { iconName in
                        Button {
                            store.setPinboardIcon(selectedBoard, iconName: iconName)
                        } label: {
                            Label(
                                pinboardIconDisplayName(iconName),
                                systemImage: selectedBoard.iconName == iconName ? "checkmark" : iconName
                            )
                        }
                    }
                }
                Menu("Page Color") {
                    ForEach(AppConstants.pinboardColorNames, id: \.self) { colorName in
                        Button {
                            store.setPinboardColor(selectedBoard, colorName: colorName)
                        } label: {
                            Label(
                                PinboardColor.displayName(for: colorName),
                                systemImage: selectedBoard.colorName == colorName ? "checkmark" : "circle.fill"
                            )
                        }
                    }
                }
                if selectedBoard.isLocked {
                    if !selectedBoardRequiresUnlock {
                        Button {
                            unlockedBoardIDs.remove(selectedBoard.persistentModelID)
                        } label: {
                            Label("Lock Page Now", systemImage: "lock")
                        }
                    }
                    Button {
                        removeLockBoard = selectedBoard
                    } label: {
                        Label("Remove Lock...", systemImage: "lock.slash")
                    }
                } else {
                    Button {
                        lockSetupBoard = selectedBoard
                    } label: {
                        Label("Lock Page...", systemImage: "lock")
                    }
                }
                Divider()
            }
            Button {
                newPageName = ""
                isShowingNewPageAlert = true
            } label: {
                Label("New Page...", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: selectedBoard?.iconName ?? "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selectedBoard.map { PinboardColor.color(named: $0.colorName) } ?? Color(red: 0.78, green: 0.22, blue: 0.88))
                if selectedBoard?.isLocked == true {
                    Image(systemName: selectedBoardRequiresUnlock ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                }
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

    private var isLockSetupPresented: Binding<Bool> {
        Binding(
            get: { lockSetupBoard != nil },
            set: { if !$0 { lockSetupBoard = nil } }
        )
    }

    private var isRemoveLockPresented: Binding<Bool> {
        Binding(
            get: { removeLockBoard != nil },
            set: { if !$0 { removeLockBoard = nil } }
        )
    }

    private var kindFilterBinding: Binding<String?> {
        Binding(
            get: { selectedKindFilter?.rawValue },
            set: { selectedKindFilter = $0.flatMap(ClipKind.init(rawValue:)) }
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

    private func selectBoard(_ board: Pinboard) {
        selectedBoardID = board.persistentModelID
    }

    private func focusInlineUnlockIfNeeded() {
        if selectedBoardRequiresUnlock {
            focusInlineUnlockField()
        } else {
            isInlineUnlockFocused = false
        }
    }

    private func focusInlineUnlockField() {
        DispatchQueue.main.async {
            isSearchFocused = false
            isInlineUnlockFocused = false
            DispatchQueue.main.async {
                isInlineUnlockFocused = true
            }
        }
    }

    private func resetInlineUnlock() {
        inlineUnlockPassword = ""
        inlineUnlockError = ""
        biometricPromptBoardID = nil
        isBiometricUnlockRunning = false
    }

    private func submitInlineUnlock() {
        guard let selectedBoard, selectedBoardRequiresUnlock else { return }
        guard !inlineUnlockPassword.isEmpty else {
            inlineUnlockError = ""
            focusInlineUnlockField()
            return
        }
        if store.unlockPinboard(selectedBoard, password: inlineUnlockPassword) {
            unlockedBoardIDs.insert(selectedBoard.persistentModelID)
            resetInlineUnlock()
            isInlineUnlockFocused = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            inlineUnlockError = "Wrong password."
            inlineUnlockPassword = ""
            focusInlineUnlockField()
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func toggleSelection(for item: ClipItem) {
        let id = item.persistentModelID
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
        }
    }

    private func showDetails(for item: ClipItem) {
        detailPath = [item.persistentModelID]
    }

    private func deleteSelection() {
        let selected = Set(selectedItemIDs)
        for item in filteredItems where selected.contains(item.persistentModelID) {
            store.delete(item)
        }
        selectedItemIDs.removeAll()
        isSelecting = false
    }

    private func saveCurrentClipboard() {
        guard let content = ClipboardReader.readCurrentContent(),
              let item = store.insert(content) else {
            showManualAddError("The clipboard is empty or its content could not be saved.")
            return
        }
        scheduleOCRUpdate(for: item)
        if let selectedBoard {
            store.assign(item, to: selectedBoard)
        }
        showSavedFeedback()
    }

    private func refreshSync() {
        syncStatus.refresh()
        store.dedupeSweep()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func addManualNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showManualAddError("Write something before saving the note.")
            return
        }
        let content = CapturedContent(kind: .text, text: trimmed, sourceAppName: "ClipStory")
        guard store.insertManual(content, to: selectedBoard) != nil else {
            showManualAddError("The note could not be saved.")
            return
        }
        showSavedFeedback()
    }

    private func handleManualFileImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            addManualFile(from: url)
        } catch {
            showManualAddError(error.localizedDescription)
        }
    }

    private func addManualFile(from url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

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
                imageData: isImage ? data : nil,
                fileData: data,
                fileName: url.lastPathComponent,
                fileTypeIdentifier: type?.identifier ?? "public.data",
                sourceAppName: "ClipStory"
            )
            guard let item = store.insertManual(content, to: selectedBoard) else {
                showManualAddError("The file could not be saved.")
                return
            }
            scheduleOCRUpdate(for: item)
            showSavedFeedback()
        } catch {
            showManualAddError(error.localizedDescription)
        }
    }

    private func scheduleOCRUpdate(for item: ClipItem) {
        guard let imageData = item.imageData else { return }
        let contentHash = item.contentHash
        let store = store
        Task.detached(priority: .utility) {
            let text = ImageTextRecognizer.recognizedText(in: imageData)
            await MainActor.run {
                store.updateRecognizedText(contentHash: contentHash, text: text)
            }
        }
    }

    private var maxFileSizeMessage: String {
        "Files larger than \(ByteCountFormatter.string(fromByteCount: Int64(AppConstants.maxManualFileByteCount), countStyle: .file)) cannot be saved yet."
    }

    private func showManualAddError(_ message: String) {
        manualAddErrorMessage = message
        isShowingManualAddError = true
    }

    private func showSavedFeedback() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copyFeedbackDismissal?.cancel()
        withAnimation {
            copyFeedback = CopyFeedback(text: "Saved", systemImage: "checkmark.circle.fill")
        }
        copyFeedbackDismissal = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation { copyFeedback = nil }
        }
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

    private func pinboardIconDisplayName(_ iconName: String) -> String {
        iconName
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "2x2", with: "grid")
            .capitalized
    }

    private func showCopyFeedback(success: Bool) {
        if success {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        copyFeedbackDismissal?.cancel()
        withAnimation { copyFeedback = CopyFeedback(success: success) }
        copyFeedbackDismissal = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation { copyFeedback = nil }
        }
    }

    private func copyItem(_ item: ClipItem) {
        let success = ClipboardWriter.copy(item)
        if success {
            recentlyCopiedItemID = item.persistentModelID
            copiedItemDismissal?.cancel()
            copiedItemDismissal = Task {
                try? await Task.sleep(for: .seconds(0.9))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.16)) {
                        if recentlyCopiedItemID == item.persistentModelID {
                            recentlyCopiedItemID = nil
                        }
                    }
                }
            }
        }
        showCopyFeedback(success: success)
    }

    private func attemptBiometricUnlockIfAvailable() {
        guard let selectedBoard, selectedBoardRequiresUnlock else { return }
        let boardID = selectedBoard.persistentModelID
        guard biometricPromptBoardID != boardID, !isBiometricUnlockRunning else { return }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return }

        biometricPromptBoardID = boardID
        isBiometricUnlockRunning = true
        context.localizedCancelTitle = "Use Password"
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Unlock \(selectedBoard.displayName) in ClipStory."
        ) { success, _ in
            Task { @MainActor in
                isBiometricUnlockRunning = false
                guard selectedBoardID == boardID, selectedBoardRequiresUnlock else { return }
                if success {
                    unlockedBoardIDs.insert(boardID)
                    resetInlineUnlock()
                    isInlineUnlockFocused = false
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } else {
                    focusInlineUnlockField()
                }
            }
        }
    }
}

private struct ManualNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    let onSave: (String) -> Void

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .background(Color.black)
                .foregroundStyle(.white)
                .padding()
                .navigationTitle("New Note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            onSave(text)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}

private struct PinboardLockSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var errorText = ""

    let boardName: String
    let onSave: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                    SecureField("Confirm Password", text: $confirmation)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Unlocking is required before this page shows clips.")
                        if !errorText.isEmpty {
                            Text(errorText)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Lock \(boardName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lock") { save() }
                        .disabled(password.count < PinboardLocking.minimumPasswordLength || confirmation.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        guard password == confirmation else {
            errorText = "Passwords do not match."
            return
        }
        guard password.count >= PinboardLocking.minimumPasswordLength else {
            errorText = "Use at least \(PinboardLocking.minimumPasswordLength) characters."
            return
        }
        onSave(password)
        dismiss()
    }
}

private struct PinboardUnlockSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var errorText = ""

    let boardName: String
    let title: String
    let actionTitle: String
    let onSubmit: (String) -> Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                        .onSubmit { submit() }
                } header: {
                    Text(boardName)
                } footer: {
                    if !errorText.isEmpty {
                        Text(errorText)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) { submit() }
                        .disabled(password.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func submit() {
        if onSubmit(password) {
            dismiss()
        } else {
            errorText = "Wrong password."
            password = ""
        }
    }
}

private struct ClipGridCardView: View {
    let item: ClipItem
    let isSelected: Bool
    let isRecentlyCopied: Bool
    private static let cardHeight: CGFloat = 196
    private static let headerHeight: CGFloat = 52
    private static let footerHeight: CGFloat = 25
    private static let previewHeight = cardHeight - headerHeight - footerHeight

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
                .frame(maxWidth: .infinity)
                .frame(height: Self.previewHeight)
                .clipped()
            footer
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.cardHeight)
        .background(Color(red: 0.10, green: 0.10, blue: 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isSelected ? 10 : 8, style: .continuous)
                .stroke(isSelected ? Color(red: 0.20, green: 0.47, blue: 0.96) : Color.white.opacity(0.06),
                        lineWidth: isSelected ? 3 : 1)
                .padding(isSelected ? -2 : 0)
        }
        .overlay(alignment: .center) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.white, Color.accentColor)
            } else if isRecentlyCopied {
                Label("Copied", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.62), in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.kind.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(Self.relativeFormatter.localizedString(for: item.createdAt, relativeTo: Date()))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            sourceBadge
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .frame(height: Self.headerHeight, alignment: .top)
        .background(headerBackground)
    }

    private var sourceBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.92))
            Image(systemName: sourceSymbolName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(sourceSymbolColor)
        }
        .frame(width: 28, height: 28)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }

    private var headerBackground: LinearGradient {
        LinearGradient(
            colors: [accentColor.opacity(0.72), accentColor.opacity(0.54)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .text:
            Text(item.preview)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
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
            thumbnailView(thumbnail)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let thumbnail = ClipThumbnailLoader.thumbnail(for: item) {
            thumbnailView(thumbnail)
        } else {
            centeredIcon("photo")
        }
    }

    @ViewBuilder
    private var filePreview: some View {
        if let thumbnail = ClipThumbnailLoader.thumbnail(for: item) {
            ZStack(alignment: .bottomLeading) {
                thumbnailView(thumbnail)

                Text(item.fileName ?? item.preview)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .padding(8)
            }
        } else {
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
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let footerText {
                Text(footerText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            }
            if let board = item.pinboard {
                Image(systemName: board.iconName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PinboardColor.color(named: board.colorName))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.footerHeight)
    }

    private func thumbnailView(_ image: UIImage) -> some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .clipped()
    }

    private func centeredIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 34, weight: .light))
            .foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footerText: String? {
        switch item.kind {
        case .text, .url:
            guard let text = item.text else { return nil }
            let count = text.count
            let formatted = Self.countFormatter.string(from: NSNumber(value: count)) ?? String(count)
            return count == 1 ? "1 character" : "\(formatted) characters"
        case .image:
            guard let data = item.imageData else { return nil }
            return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        case .file:
            if let data = item.fileData {
                return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            }
            if let data = item.imageData {
                return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            }
            return item.fileName
        }
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

    private var sourceSymbolName: String {
        let bundleID = item.sourceAppBundleID?.lowercased() ?? ""
        let sourceName = item.sourceAppName?.lowercased() ?? ""
        if bundleID.contains("chrome") { return "globe" }
        if bundleID.contains("safari") { return "safari" }
        if bundleID.contains("terminal") || sourceName.contains("terminal") { return "terminal" }
        if bundleID.contains("slack") || sourceName.contains("slack") { return "bubble.left.and.bubble.right.fill" }
        if sourceName.contains("iphone") { return "iphone" }
        if item.kind == .url { return "link" }
        return item.kind.systemImageName
    }

    private var sourceSymbolColor: Color {
        switch sourceSymbolName {
        case "globe", "safari": return .blue
        case "terminal": return .black
        case "bubble.left.and.bubble.right.fill": return .purple
        default: return accentColor
        }
    }
}
