import Foundation
import SwiftData
import XCTest

/// Covers the `isSavedToPage` marker that protects page clips from prune and
/// clear. CloudKit can import a ClipItem before its Pinboard record (and the
/// relationship link) arrives, so `pinboard == nil` alone must never mean
/// "disposable" — the scalar flag travels in the same record and closes that
/// race.
final class ClipStorePruneTests: XCTestCase {
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

    @MainActor
    @discardableResult
    private func insertItem(text: String, createdAt: Date) -> ClipItem {
        let item = ClipItem(content: CapturedContent(kind: .text, text: text), createdAt: createdAt)
        container.mainContext.insert(item)
        return item
    }

    // MARK: - Prune protection

    @MainActor
    func testFlaggedClipWithPendingRelationshipSurvivesPrune() throws {
        let store = makeStore()
        // Simulates a page clip imported from CloudKit whose Pinboard record
        // has not arrived yet: flag set, relationship still nil.
        let pageClip = insertItem(text: "page clip", createdAt: Date(timeIntervalSince1970: 1_000))
        pageClip.isSavedToPage = true
        insertItem(text: "old plain", createdAt: Date(timeIntervalSince1970: 2_000))
        insertItem(text: "new plain", createdAt: Date(timeIntervalSince1970: 3_000))
        store.save()

        store.setHistoryLimit(1)

        let remaining = try fetchAll()
        XCTAssertEqual(remaining.count, 2)
        let texts = Set(remaining.compactMap(\.text))
        XCTAssertTrue(texts.contains("page clip"))
        XCTAssertTrue(texts.contains("new plain"))
    }

    @MainActor
    func testClearUnpinnedKeepsFlaggedClip() throws {
        let store = makeStore()
        let pageClip = insertItem(text: "page clip", createdAt: Date(timeIntervalSince1970: 1_000))
        pageClip.isSavedToPage = true
        insertItem(text: "plain", createdAt: Date(timeIntervalSince1970: 2_000))
        store.save()

        store.clearUnpinned()

        let remaining = try fetchAll()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.text, "page clip")
    }

    // MARK: - Flag maintenance

    @MainActor
    func testAssignSetsAndClearsFlag() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.createPinboard(named: "Board"))
        let item = insertItem(text: "clip", createdAt: Date(timeIntervalSince1970: 1_000))
        store.save()

        store.assign(item, to: board)
        XCTAssertTrue(item.isSavedToPage)

        store.assign(item, to: nil)
        XCTAssertFalse(item.isSavedToPage)
    }

    @MainActor
    func testInsertManualSetsFlagOnlyWhenBoardGiven() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.createPinboard(named: "Board"))

        let onBoard = try XCTUnwrap(
            store.insertManual(CapturedContent(kind: .text, text: "saved"), to: board)
        )
        XCTAssertTrue(onBoard.isSavedToPage)

        let plain = try XCTUnwrap(
            store.insertManual(CapturedContent(kind: .text, text: "loose"))
        )
        XCTAssertFalse(plain.isSavedToPage)
    }

    @MainActor
    func testDeletePinboardClearsFlagsOfItsItems() throws {
        let store = makeStore()
        let board = try XCTUnwrap(store.createPinboard(named: "Board"))
        let item = insertItem(text: "clip", createdAt: Date(timeIntervalSince1970: 1_000))
        store.assign(item, to: board)

        store.deletePinboard(board)

        XCTAssertNil(item.pinboard)
        XCTAssertFalse(item.isSavedToPage)
    }
}
