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
    @State private var detailPath: [PersistentIdentifier] = []

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
        NavigationStack(path: $detailPath) {
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar
                    if isSearchVisible {
                        searchBar
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
                .padding(.bottom, 210)
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
            Button {
                showCopyFeedback(success: ClipboardWriter.copy(item))
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
            showDetails(for: item)
        } label: {
            Label("View Details", systemImage: "doc.text.magnifyingglass")
        }
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
                    Label(board.displayName, systemImage: selectedBoardID == board.persistentModelID ? "checkmark" : board.iconName)
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
