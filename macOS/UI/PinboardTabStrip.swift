import AppKit
import SwiftData
import SwiftUI

/// Which collection the panel is showing.
enum PanelTab: Hashable {
    case history
    case board(PersistentIdentifier)
}

/// Maps the shared pinboard color names to concrete colors.
enum PinboardPalette {
    static func color(for name: String) -> Color {
        Color(nsColor: nsColor(for: name))
    }

    static func nsColor(for name: String) -> NSColor {
        switch name {
        case "magenta": return NSColor(calibratedRed: 0.93, green: 0.21, blue: 0.88, alpha: 1)
        case "blue": return .systemBlue
        case "purple": return .systemPurple
        case "orange": return .systemOrange
        case "teal": return .systemTeal
        case "pink": return .systemPink
        case "indigo": return .systemIndigo
        case "red": return .systemRed
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        default: return .systemGray
        }
    }
}

/// "Clipboard History" + one tab per pinboard + "+", Paste-style: the
/// selected tab gets a white-12% pill. Rename happens inline; color and
/// delete live in the tab's context menu.
@MainActor
struct PinboardTabStrip: View {
    let pinboards: [Pinboard]
    @Binding var selection: PanelTab

    @EnvironmentObject private var store: ClipStore
    @State private var renamingBoardID: PersistentIdentifier?
    @State private var renameText = ""
    @State private var boardPendingDelete: Pinboard?
    @FocusState private var renameFocus: PersistentIdentifier?

    var body: some View {
        HStack(spacing: 4) {
            historyTab
            ForEach(pinboards, id: \.persistentModelID) { board in
                boardTab(board)
            }
            addButton
        }
        .onChange(of: renameFocus) { _, newValue in
            if newValue == nil { commitPendingRename() }
        }
        .alert(
            "Delete page?",
            isPresented: Binding(
                get: { boardPendingDelete != nil },
                set: { if !$0 { boardPendingDelete = nil } }
            ),
            presenting: boardPendingDelete
        ) { board in
            Button("Delete", role: .destructive) { delete(board) }
            Button("Cancel", role: .cancel) {}
        } message: { board in
            Text("\u{201C}\(board.displayName)\u{201D} will be deleted. Its clips go back to your clipboard history.")
        }
    }

    // MARK: - Tabs

    private var historyTab: some View {
        tabButton(isSelected: selection == .history, action: { selection = .history }) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11.5, weight: .medium))
                Text("Clipboard History")
            }
        }
    }

    @ViewBuilder
    private func boardTab(_ board: Pinboard) -> some View {
        let id = board.persistentModelID
        if renamingBoardID == id {
            renameField(for: board)
        } else {
            tabButton(isSelected: selection == .board(id), action: { selection = .board(id) }) {
                HStack(spacing: 6) {
                    Image(systemName: board.iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PinboardPalette.color(for: board.colorName))
                    Text(board.displayName)
                }
            }
            .contextMenu {
                Button("Rename\u{2026}") { beginRename(board) }
                Menu("Color") {
                    ForEach(AppConstants.pinboardColorNames, id: \.self) { name in
                        Button {
                            store.setPinboardColor(board, colorName: name)
                        } label: {
                            Label {
                                Text(name.capitalized)
                            } icon: {
                                Image(nsImage: Self.swatchImage(
                                    colorName: name,
                                    isSelected: board.colorName == name
                                ))
                            }
                        }
                    }
                }
                Menu("Icon") {
                    ForEach(AppConstants.pinboardIconNames, id: \.self) { iconName in
                        Button {
                            store.setPinboardIcon(board, iconName: iconName)
                        } label: {
                            Label {
                                Text(Self.iconDisplayName(iconName))
                            } icon: {
                                Image(systemName: board.iconName == iconName ? "checkmark" : iconName)
                            }
                        }
                    }
                }
                Divider()
                Button("Delete Page\u{2026}", role: .destructive) { boardPendingDelete = board }
            }
        }
    }

    private func renameField(for board: Pinboard) -> some View {
        HStack(spacing: 6) {
            Image(systemName: board.iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PinboardPalette.color(for: board.colorName))
            TextField("Name", text: $renameText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 110)
                .focused($renameFocus, equals: board.persistentModelID)
                .onSubmit { commitRename(board) }
                .onKeyPress(.escape) {
                    cancelRename()
                    return .handled
                }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.12)))
    }

    private func tabButton<Content: View>(
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.62))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        Capsule().fill(Color.white.opacity(0.12))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var addButton: some View {
        Button(action: createPinboard) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New page")
    }

    // MARK: - Actions

    private func createPinboard() {
        guard let board = store.createPinboard(named: "Untitled") else { return }
        selection = .board(board.persistentModelID)
        beginRename(board)
    }

    private func beginRename(_ board: Pinboard) {
        renameText = board.name
        renamingBoardID = board.persistentModelID
        // The field only exists on the next render pass; focus it then.
        DispatchQueue.main.async {
            renameFocus = board.persistentModelID
        }
    }

    private func commitRename(_ board: Pinboard) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != board.name {
            store.renamePinboard(board, to: trimmed)
        }
        renamingBoardID = nil
        renameFocus = nil
    }

    /// Focus left the rename field (click elsewhere): commit like Paste does.
    private func commitPendingRename() {
        guard
            let id = renamingBoardID,
            let board = pinboards.first(where: { $0.persistentModelID == id })
        else {
            renamingBoardID = nil
            return
        }
        commitRename(board)
    }

    private func cancelRename() {
        renamingBoardID = nil
        renameFocus = nil
    }

    private func delete(_ board: Pinboard) {
        if selection == .board(board.persistentModelID) {
            selection = .history
        }
        boardPendingDelete = nil
        store.deletePinboard(board)
    }

    // MARK: - Swatches

    /// Menus ignore SwiftUI foreground colors, so color choices are rendered
    /// as small NSImage swatches; the current color gets a white ring.
    private static func swatchImage(colorName: String, isSelected: Bool) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        return NSImage(size: size, flipped: false) { rect in
            PinboardPalette.nsColor(for: colorName).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            if isSelected {
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
    }

    private static func iconDisplayName(_ iconName: String) -> String {
        iconName
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "2x2", with: "grid")
            .capitalized
    }
}
