import Foundation
import SwiftData

/// Pinboard CRUD and item assignment.
extension ClipStore {
    func pinboards() -> [Pinboard] {
        do {
            let all = try context.fetch(FetchDescriptor<Pinboard>())
            return all.sorted { a, b in
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.dedupID.uuidString < b.dedupID.uuidString
            }
        } catch {
            logger.error("Failed to fetch pinboards: \(error)")
            return []
        }
    }

    @discardableResult
    func createPinboard(named name: String, colorName: String? = nil) -> Pinboard? {
        let existing = pinboards()
        let nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        let color = colorName
            ?? AppConstants.pinboardColorNames[nextOrder % AppConstants.pinboardColorNames.count]
        let icon = AppConstants.pinboardIconNames[nextOrder % AppConstants.pinboardIconNames.count]
        let board = Pinboard(name: name, colorName: color, iconName: icon, sortOrder: nextOrder)
        context.insert(board)
        save()
        return board
    }

    func renamePinboard(_ board: Pinboard, to name: String) {
        board.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func setPinboardColor(_ board: Pinboard, colorName: String) {
        guard AppConstants.pinboardColorNames.contains(colorName) else { return }
        board.colorName = colorName
        save()
    }

    func setPinboardIcon(_ board: Pinboard, iconName: String) {
        guard AppConstants.pinboardIconNames.contains(iconName) else { return }
        board.iconName = iconName
        save()
    }

    /// Deletes the board; its items return to plain history (nullify rule).
    func deletePinboard(_ board: Pinboard) {
        context.delete(board)
        save()
    }

    /// Moves an item onto a board (or back to history with nil).
    func assign(_ item: ClipItem, to board: Pinboard?) {
        item.pinboard = board
        save()
    }
}
