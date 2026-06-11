import Foundation
import SwiftData
import XCTest

/// Covers the ClipStore pinboards extension: creation defaults, deterministic
/// ordering, item assignment, and the nullify delete rule that returns items
/// to plain history when a board is deleted.
final class PinboardTests: XCTestCase {
    private var container: ModelContainer!
    private var previousLocalInsertCount: Any?

    /// Mirrors ClipStore's private local-insert counter UserDefaults key
    /// (store.insert increments it; snapshot so tests leave no trace).
    private static let localInsertCountKey = "localInsertCount"

    override func setUp() async throws {
        previousLocalInsertCount = UserDefaults.standard.object(forKey: Self.localInsertCountKey)
        UserDefaults.standard.removeObject(forKey: Self.localInsertCountKey)
        container = try ModelContainerFactory.makeInMemory()
    }

    override func tearDown() async throws {
        if let previousLocalInsertCount {
            UserDefaults.standard.set(previousLocalInsertCount, forKey: Self.localInsertCountKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.localInsertCountKey)
        }
        previousLocalInsertCount = nil
        container = nil
    }

    // MARK: - Helpers

    @MainActor
    private func makeStore() -> ClipStore {
        ClipStore(container: container)
    }

    @MainActor
    private func fetchAllItems() throws -> [ClipItem] {
        try container.mainContext.fetch(FetchDescriptor<ClipItem>())
    }

    // MARK: - Creation

    @MainActor
    func testCreatePinboardAssignsIncrementingSortOrderAndCyclingColors() throws {
        let store = makeStore()
        let colorCount = AppConstants.pinboardColorNames.count

        var boards: [Pinboard] = []
        for index in 0..<(colorCount + 2) {
            boards.append(try XCTUnwrap(store.createPinboard(named: "Board \(index)")))
        }

        for (index, board) in boards.enumerated() {
            XCTAssertEqual(board.sortOrder, index)
            // Default colors cycle through the full palette and wrap around.
            XCTAssertEqual(board.colorName, AppConstants.pinboardColorNames[index % colorCount])
        }
        XCTAssertEqual(store.pinboards().count, colorCount + 2)
    }

    @MainActor
    func testCreatePinboardHonorsExplicitColor() throws {
        let store = makeStore()

        let board = try XCTUnwrap(store.createPinboard(named: "Teal Board", colorName: "teal"))

        XCTAssertEqual(board.colorName, "teal")
        XCTAssertEqual(board.displayName, "Teal Board")
    }

    // MARK: - Ordering

    @MainActor
    func testPinboardsOrderBySortOrderThenCreatedAtThenDedupID() throws {
        let store = makeStore()
        let context = container.mainContext

        let second = Pinboard(name: "second", sortOrder: 1)
        let first = Pinboard(name: "first", sortOrder: 0)

        let earlier = Pinboard(name: "earlier", sortOrder: 2)
        earlier.createdAt = Date(timeIntervalSince1970: 1_000)
        let later = Pinboard(name: "later", sortOrder: 2)
        later.createdAt = Date(timeIntervalSince1970: 2_000)

        let sharedDate = Date(timeIntervalSince1970: 3_000)
        let lowID = Pinboard(name: "low-id", sortOrder: 3)
        lowID.createdAt = sharedDate
        lowID.dedupID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let highID = Pinboard(name: "high-id", sortOrder: 3)
        highID.createdAt = sharedDate
        highID.dedupID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))

        // Insert deliberately scrambled; ordering must come from sorting alone.
        for board in [highID, second, later, lowID, first, earlier] {
            context.insert(board)
        }
        store.save()

        XCTAssertEqual(
            store.pinboards().map(\.name),
            ["first", "second", "earlier", "later", "low-id", "high-id"]
        )
    }

    // MARK: - Assignment

    @MainActor
    func testAssignAndUnassignItem() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.createPinboard(named: "Work"))
        let item = try XCTUnwrap(store.insert(CapturedContent(kind: .text, text: "task")))

        store.assign(item, to: board)
        XCTAssertEqual(item.pinboard?.dedupID, board.dedupID)
        XCTAssertEqual(board.items?.count, 1)
        XCTAssertEqual(board.items?.first?.dedupID, item.dedupID)

        store.assign(item, to: nil)
        XCTAssertNil(item.pinboard)
        XCTAssertTrue(board.items?.isEmpty ?? true)
    }

    // MARK: - Deletion (nullify rule)

    @MainActor
    func testDeletePinboardLeavesItemsAliveWithNilBoard() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.createPinboard(named: "Doomed"))
        let first = try XCTUnwrap(store.insert(CapturedContent(kind: .text, text: "survivor-1")))
        let second = try XCTUnwrap(store.insert(CapturedContent(kind: .text, text: "survivor-2")))
        store.assign(first, to: board)
        store.assign(second, to: board)

        store.deletePinboard(board)

        XCTAssertTrue(store.pinboards().isEmpty)
        // The nullify rule must return members to plain history, not delete them.
        let items = try fetchAllItems()
        XCTAssertEqual(Set(items.compactMap(\.text)), ["survivor-1", "survivor-2"])
        XCTAssertTrue(items.allSatisfy { $0.pinboard == nil })
    }

    // MARK: - Rename / color

    @MainActor
    func testRenamePinboardTrimsWhitespace() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.createPinboard(named: "Old"))

        store.renamePinboard(board, to: "  New Name \n")

        XCTAssertEqual(board.name, "New Name")
    }

    @MainActor
    func testSetPinboardColorRejectsUnknownNames() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.createPinboard(named: "Colorful"))
        let original = board.colorName

        store.setPinboardColor(board, colorName: "not-a-color")
        XCTAssertEqual(board.colorName, original)

        let valid = try XCTUnwrap(AppConstants.pinboardColorNames.last)
        store.setPinboardColor(board, colorName: valid)
        XCTAssertEqual(board.colorName, valid)
    }

    // MARK: - Locking

    @MainActor
    func testLockPinboardStoresSaltedHashAndVerifiesPassword() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.createPinboard(named: "Secrets"))

        XCTAssertTrue(store.lockPinboard(board, password: "env-keys"))

        XCTAssertTrue(board.isLocked)
        XCTAssertFalse(board.lockSalt.isEmpty)
        XCTAssertFalse(board.lockHash.isEmpty)
        XCTAssertNotEqual(board.lockHash, "env-keys")
        XCTAssertTrue(store.unlockPinboard(board, password: "env-keys"))
        XCTAssertFalse(store.unlockPinboard(board, password: "wrong"))
    }

    @MainActor
    func testLockPinboardRejectsShortPassword() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.createPinboard(named: "Secrets"))

        XCTAssertFalse(store.lockPinboard(board, password: "123"))

        XCTAssertFalse(board.isLocked)
        XCTAssertTrue(board.lockSalt.isEmpty)
        XCTAssertTrue(board.lockHash.isEmpty)
    }

    @MainActor
    func testRemovePinboardLockRequiresPassword() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.createPinboard(named: "Secrets"))
        XCTAssertTrue(store.lockPinboard(board, password: "env-keys"))

        XCTAssertFalse(store.removePinboardLock(board, password: "wrong"))
        XCTAssertTrue(board.isLocked)

        XCTAssertTrue(store.removePinboardLock(board, password: "env-keys"))
        XCTAssertFalse(board.isLocked)
        XCTAssertTrue(board.lockSalt.isEmpty)
        XCTAssertTrue(board.lockHash.isEmpty)
    }
}
