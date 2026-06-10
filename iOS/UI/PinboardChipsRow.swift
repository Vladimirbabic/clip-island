import SwiftData
import SwiftUI

/// Horizontal chip row under the navigation bar: a "History" chip plus one
/// chip per pinboard (colored dot + name). The selected chip is filled.
/// Chip context menus offer Rename, Color, and Delete.
struct PinboardChipsRow: View {
    @EnvironmentObject private var store: ClipStore

    let pinboards: [Pinboard]
    @Binding var selectedBoardID: PersistentIdentifier?

    @State private var renameTarget: Pinboard?
    @State private var renameText = ""
    @State private var deleteTarget: Pinboard?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                historyChip
                ForEach(pinboards) { board in
                    chip(for: board)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .alert("Rename Page", isPresented: isRenamePresented) {
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            "Delete \(deleteTarget?.displayName ?? "Page")?",
            isPresented: isDeletePresented,
            titleVisibility: .visible
        ) {
            Button("Delete Page", role: .destructive) { commitDelete() }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Items on this page return to your history.")
        }
    }

    // MARK: - Chips

    /// "History" also wins when the selected board no longer exists (e.g.
    /// deleted on another device), matching the list's fallback filter.
    private var isHistorySelected: Bool {
        !pinboards.contains { $0.persistentModelID == selectedBoardID }
    }

    private var historyChip: some View {
        Button {
            selectedBoardID = nil
        } label: {
            chipLabel(isSelected: isHistorySelected) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                Text("History")
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isHistorySelected ? .isSelected : [])
    }

    private func chip(for board: Pinboard) -> some View {
        let isSelected = selectedBoardID == board.persistentModelID
        return Button {
            selectedBoardID = board.persistentModelID
        } label: {
            chipLabel(isSelected: isSelected) {
                Circle()
                    .fill(PinboardColor.color(named: board.colorName))
                    .frame(width: 9, height: 9)
                Text(board.displayName)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button {
                renameText = board.name
                renameTarget = board
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            colorMenu(for: board)
            Button(role: .destructive) {
                deleteTarget = board
            } label: {
                Label("Delete Page…", systemImage: "trash")
            }
        }
    }

    private func chipLabel(
        isSelected: Bool, @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(spacing: 6, content: content)
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isSelected ? Color(.systemFill) : Color(.quaternarySystemFill))
            )
    }

    private func colorMenu(for board: Pinboard) -> some View {
        Menu {
            ForEach(AppConstants.pinboardColorNames, id: \.self) { name in
                Button {
                    store.setPinboardColor(board, colorName: name)
                } label: {
                    if board.colorName == name {
                        Label(PinboardColor.displayName(for: name), systemImage: "checkmark")
                    } else {
                        Text(PinboardColor.displayName(for: name))
                    }
                }
            }
        } label: {
            Label("Color", systemImage: "circle.fill")
        }
    }

    // MARK: - Alert plumbing

    private var isRenamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private var isDeletePresented: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private func commitRename() {
        guard let board = renameTarget else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            store.renamePinboard(board, to: trimmed)
        }
        renameTarget = nil
    }

    private func commitDelete() {
        guard let board = deleteTarget else { return }
        if selectedBoardID == board.persistentModelID {
            selectedBoardID = nil
        }
        store.deletePinboard(board)
        deleteTarget = nil
    }
}
