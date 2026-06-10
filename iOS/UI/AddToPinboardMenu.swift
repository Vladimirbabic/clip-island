import SwiftData
import SwiftUI

/// Shared menu content for assigning a clip to a pinboard: an "Add to
/// Pinboard" submenu (existing boards + "New Pinboard…") plus a "Remove from
/// Pinboard" action when the clip is already on one. Used from the history
/// row context menu and from the detail toolbar.
struct AddToPinboardMenu: View {
    @EnvironmentObject private var store: ClipStore

    let item: ClipItem
    let pinboards: [Pinboard]
    /// The host presents the "New Pinboard" name alert and assigns the item.
    let onCreateNewPinboard: () -> Void

    var body: some View {
        Group {
            Menu {
                ForEach(pinboards) { board in
                    boardButton(for: board)
                }
                if !pinboards.isEmpty {
                    Divider()
                }
                Button(action: onCreateNewPinboard) {
                    Label("New Page…", systemImage: "plus")
                }
            } label: {
                Label("Add to Page", systemImage: "square.grid.2x2")
            }

            if item.pinboard != nil {
                Button {
                    store.assign(item, to: nil)
                } label: {
                    Label("Remove from Page", systemImage: "minus.circle")
                }
            }
        }
    }

    private func boardButton(for board: Pinboard) -> some View {
        let isCurrent = item.pinboard?.persistentModelID == board.persistentModelID
        return Button {
            store.assign(item, to: board)
        } label: {
            if isCurrent {
                Label(board.displayName, systemImage: "checkmark")
            } else {
                Text(board.displayName)
            }
        }
        .disabled(isCurrent)
    }
}
