import Foundation
import SwiftData
import XCTest

/// Covers `ClipStore.dedupeSweep()`: collapsing same-content items that
/// CloudKit sync duplicated across devices. Keeper choice must be
/// deterministic (newest createdAt, tie: smallest dedupID string) and must
/// inherit pin/board/source metadata so no user intent is lost.
final class ClipStoreDedupeTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try ModelContainerFactory.makeInMemory()
    }

    override func tearDown() async throws {
        container = nil
    }

    // MARK: - Helpers

    @MainActor
    private func makeStore() -> ClipStore {
        ClipStore(container: container)
    }

    @MainActor
    private func fetchAll() throws -> [ClipItem] {
        try container.mainContext.fetch(FetchDescriptor<ClipItem>())
    }

    /// Inserts an item directly into the context (bypassing the store's
    /// insert-time dedupe) to simulate duplicates arriving via CloudKit sync.
    @MainActor
    @discardableResult
    private func insertItem(text: String, createdAt: Date, dedupID: UUID? = nil) -> ClipItem {
        let item = ClipItem(content: CapturedContent(kind: .text, text: text), createdAt: createdAt)
        if let dedupID {
            item.dedupID = dedupID
        }
        container.mainContext.insert(item)
        return item
    }

    // MARK: - Keeper selection

    @MainActor
    func testSweepCollapsesDuplicatesToNewestCreatedAt() throws {
        let store = makeStore()
        insertItem(text: "dup", createdAt: Date(timeIntervalSince1970: 1_000))
        let newest = insertItem(text: "dup", createdAt: Date(timeIntervalSince1970: 3_000))
        insertItem(text: "dup", createdAt: Date(timeIntervalSince1970: 2_000))
        let newestID = newest.dedupID
        store.save()

        store.dedupeSweep()

        let remaining = try fetchAll()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.dedupID, newestID)
        XCTAssertEqual(remaining.first?.createdAt, Date(timeIntervalSince1970: 3_000))
    }

    @MainActor
    func testSweepTieBreaksOnSmallestDedupIDString() throws {
        let store = makeStore()
        let sharedDate = Date(timeIntervalSince1970: 5_000)
        let lowID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let highID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        insertItem(text: "tie", createdAt: sharedDate, dedupID: highID)
        insertItem(text: "tie", createdAt: sharedDate, dedupID: lowID)
        store.save()

        store.dedupeSweep()

        let remaining = try fetchAll()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.dedupID, lowID)
    }

    // MARK: - Metadata inheritance

    @MainActor
    func testKeeperInheritsPinAndFillsNilMetadata() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.createPinboard(named: "Inherit"))
        let keeper = insertItem(text: "merge-me", createdAt: Date(timeIntervalSince1970: 2_000))
        let duplicate = insertItem(text: "merge-me", createdAt: Date(timeIntervalSince1970: 1_000))
        duplicate.isPinned = true
        duplicate.pinboard = board
        duplicate.sourceAppName = "Safari"
        duplicate.sourceAppBundleID = "com.apple.Safari"
        duplicate.linkTitle = "Example Title"
        store.save()

        store.dedupeSweep()

        let remaining = try fetchAll()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.dedupID, keeper.dedupID)
        XCTAssertTrue(keeper.isPinned)
        XCTAssertEqual(keeper.pinboard?.dedupID, board.dedupID)
        XCTAssertEqual(keeper.sourceAppName, "Safari")
        XCTAssertEqual(keeper.sourceAppBundleID, "com.apple.Safari")
        XCTAssertEqual(keeper.linkTitle, "Example Title")
        // Inheriting a board also inherits the prune-protection flag.
        XCTAssertTrue(keeper.isSavedToPage)
    }

    @MainActor
    func testKeeperKeepsOwnMetadataWhenAlreadySet() throws {
        let store = makeStore()
        let sharedBoard = try XCTUnwrap(store.createPinboard(named: "Shared Board"))
        let keeper = insertItem(text: "keep-mine", createdAt: Date(timeIntervalSince1970: 2_000))
        keeper.pinboard = sharedBoard
        keeper.sourceAppName = "Notes"
        keeper.sourceAppBundleID = "com.apple.Notes"
        keeper.linkTitle = "Keeper Title"
        keeper.customTitle = "Keeper Custom"
        keeper.recognizedText = "Keeper OCR"
        let duplicate = insertItem(text: "keep-mine", createdAt: Date(timeIntervalSince1970: 1_000))
        duplicate.pinboard = sharedBoard
        duplicate.sourceAppName = "Safari"
        duplicate.sourceAppBundleID = "com.apple.Safari"
        duplicate.linkTitle = "Duplicate Title"
        duplicate.customTitle = "Duplicate Custom"
        duplicate.recognizedText = "Duplicate OCR"
        store.save()

        store.dedupeSweep()

        XCTAssertEqual(try fetchAll().count, 1)
        // Fill-if-nil only: existing keeper metadata is never overwritten.
        XCTAssertEqual(keeper.pinboard?.dedupID, sharedBoard.dedupID)
        XCTAssertEqual(keeper.sourceAppName, "Notes")
        XCTAssertEqual(keeper.sourceAppBundleID, "com.apple.Notes")
        XCTAssertEqual(keeper.linkTitle, "Keeper Title")
        XCTAssertEqual(keeper.customTitle, "Keeper Custom")
        XCTAssertEqual(keeper.recognizedText, "Keeper OCR")
        // Neither item was pinned, so the keeper stays unpinned.
        XCTAssertFalse(keeper.isPinned)
    }

    @MainActor
    func testKeeperInheritsCustomTitleAndRecognizedText() throws {
        let store = makeStore()
        let keeper = insertItem(text: "merge-extras", createdAt: Date(timeIntervalSince1970: 2_000))
        let duplicate = insertItem(text: "merge-extras", createdAt: Date(timeIntervalSince1970: 1_000))
        duplicate.customTitle = "Renamed on Mac"
        duplicate.recognizedText = "OCR from Mac"
        duplicate.imageData = Data([0xDE, 0xAD])
        store.save()

        store.dedupeSweep()

        XCTAssertEqual(try fetchAll().count, 1)
        XCTAssertEqual(keeper.customTitle, "Renamed on Mac")
        XCTAssertEqual(keeper.recognizedText, "OCR from Mac")
        XCTAssertEqual(keeper.imageData, Data([0xDE, 0xAD]))
    }

    // MARK: - Page-aware safety rules

    @MainActor
    func testDuplicatesOnDifferentBoardsAreBothKept() throws {
        let store = makeStore()
        let keeperBoard = try XCTUnwrap(store.createPinboard(named: "Keeper Board"))
        let duplicateBoard = try XCTUnwrap(store.createPinboard(named: "Duplicate Board"))
        let keeper = insertItem(text: "two-pages", createdAt: Date(timeIntervalSince1970: 2_000))
        keeper.pinboard = keeperBoard
        let duplicate = insertItem(text: "two-pages", createdAt: Date(timeIntervalSince1970: 1_000))
        duplicate.pinboard = duplicateBoard
        store.save()

        store.dedupeSweep()

        // Same content deliberately saved to two pages is two pieces of user
        // intent, not a sync duplicate.
        XCTAssertEqual(try fetchAll().count, 2)
        XCTAssertEqual(keeper.pinboard?.dedupID, keeperBoard.dedupID)
        XCTAssertEqual(duplicate.pinboard?.dedupID, duplicateBoard.dedupID)
    }

    @MainActor
    func testDuplicateWithPendingBoardRelationshipIsDeferred() throws {
        let store = makeStore()
        let keeper = insertItem(text: "pending", createdAt: Date(timeIntervalSince1970: 2_000))
        let duplicate = insertItem(text: "pending", createdAt: Date(timeIntervalSince1970: 1_000))
        // Flag synced in, Pinboard record/relationship still in flight.
        duplicate.isSavedToPage = true
        store.save()

        store.dedupeSweep()

        // Deleting now would lose the page membership; a later sweep handles
        // it once the relationship materializes.
        XCTAssertEqual(try fetchAll().count, 2)
        _ = keeper
    }

    @MainActor
    func testSweepBackfillsFlagFromLinkedRelationship() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.createPinboard(named: "Backfill"))
        // Simulates a record written by a build that predates the flag.
        let item = insertItem(text: "legacy", createdAt: Date(timeIntervalSince1970: 1_000))
        item.pinboard = board
        XCTAssertFalse(item.isSavedToPage)
        store.save()

        store.dedupeSweep()

        XCTAssertTrue(item.isSavedToPage)
    }

    // MARK: - Non-duplicates / idempotency

    @MainActor
    func testSweepLeavesDifferentHashesUntouched() throws {
        let store = makeStore()
        insertItem(text: "alpha", createdAt: Date(timeIntervalSince1970: 1_000))
        insertItem(text: "beta", createdAt: Date(timeIntervalSince1970: 2_000))
        store.save()

        store.dedupeSweep()

        XCTAssertEqual(try fetchAll().count, 2)
    }

    @MainActor
    func testSweepIsIdempotent() throws {
        let store = makeStore()
        let keeper = insertItem(text: "dup", createdAt: Date(timeIntervalSince1970: 2_000))
        let duplicate = insertItem(text: "dup", createdAt: Date(timeIntervalSince1970: 1_000))
        duplicate.isPinned = true
        insertItem(text: "solo", createdAt: Date(timeIntervalSince1970: 3_000))
        store.save()

        store.dedupeSweep()
        let afterFirst = try fetchAll()
        XCTAssertEqual(afterFirst.count, 2)
        XCTAssertTrue(keeper.isPinned)

        store.dedupeSweep()
        let afterSecond = try fetchAll()
        XCTAssertEqual(afterSecond.count, 2)
        XCTAssertEqual(
            Set(afterFirst.map(\.dedupID)),
            Set(afterSecond.map(\.dedupID))
        )
        XCTAssertTrue(keeper.isPinned)
    }
}
