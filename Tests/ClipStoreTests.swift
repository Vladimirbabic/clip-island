import Foundation
import SwiftData
import XCTest

final class ClipStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var previousHistoryLimit: Any?
    private var previousLocalInsertCount: Any?

    /// Mirrors ClipStore's private local-insert counter UserDefaults key.
    private static let localInsertCountKey = "localInsertCount"

    override func setUp() async throws {
        // Snapshot the real defaults so tests can change them freely; restored
        // in tearDown. Removing them makes every test start from a clean slate.
        let defaults = UserDefaults.standard
        previousHistoryLimit = defaults.object(forKey: AppConstants.historyLimitKey)
        previousLocalInsertCount = defaults.object(forKey: Self.localInsertCountKey)
        defaults.removeObject(forKey: AppConstants.historyLimitKey)
        defaults.removeObject(forKey: Self.localInsertCountKey)
        container = try ModelContainerFactory.makeInMemory()
    }

    override func tearDown() async throws {
        let defaults = UserDefaults.standard
        if let previousHistoryLimit {
            defaults.set(previousHistoryLimit, forKey: AppConstants.historyLimitKey)
        } else {
            defaults.removeObject(forKey: AppConstants.historyLimitKey)
        }
        if let previousLocalInsertCount {
            defaults.set(previousLocalInsertCount, forKey: Self.localInsertCountKey)
        } else {
            defaults.removeObject(forKey: Self.localInsertCountKey)
        }
        previousHistoryLimit = nil
        previousLocalInsertCount = nil
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

    // MARK: - Insert

    @MainActor
    func testInsertCreatesItemWithFieldsAndHash() throws {
        let store = makeStore()
        let content = CapturedContent(
            kind: .url,
            text: "https://example.com",
            sourceAppName: "Safari",
            sourceAppBundleID: "com.apple.Safari"
        )

        let item = try XCTUnwrap(store.insert(content))

        XCTAssertEqual(item.kind, .url)
        XCTAssertEqual(item.text, "https://example.com")
        XCTAssertNil(item.imageData)
        XCTAssertNil(item.fileName)
        XCTAssertEqual(item.sourceAppName, "Safari")
        XCTAssertEqual(item.sourceAppBundleID, "com.apple.Safari")
        XCTAssertFalse(item.isPinned)
        XCTAssertNil(item.pinboard)
        XCTAssertNil(item.linkTitle)
        XCTAssertEqual(item.contentHash, content.contentHash)
        XCTAssertEqual(try fetchAll().count, 1)
    }

    @MainActor
    func testInsertingIdenticalContentBumpsExistingItem() throws {
        let store = makeStore()
        let content = CapturedContent(kind: .text, text: "same content")

        let first = try XCTUnwrap(store.insert(content))
        // Backdate deterministically instead of sleeping between inserts.
        let olderDate = Date(timeIntervalSinceNow: -3_600)
        first.createdAt = olderDate

        let second = try XCTUnwrap(store.insert(content))

        XCTAssertEqual(first.persistentModelID, second.persistentModelID)
        XCTAssertGreaterThan(second.createdAt, olderDate)
        XCTAssertEqual(try fetchAll().count, 1)
    }

    @MainActor
    func testInsertingDuplicateUpdatesSourceApp() throws {
        let store = makeStore()
        let first = try XCTUnwrap(
            store.insert(CapturedContent(kind: .text, text: "same content", sourceAppName: "Notes"))
        )

        let second = try XCTUnwrap(
            store.insert(
                CapturedContent(
                    kind: .text,
                    text: "same content",
                    sourceAppName: "Safari",
                    sourceAppBundleID: "com.apple.Safari"
                )
            )
        )

        XCTAssertEqual(first.persistentModelID, second.persistentModelID)
        XCTAssertEqual(second.sourceAppName, "Safari")
        XCTAssertEqual(second.sourceAppBundleID, "com.apple.Safari")
        XCTAssertEqual(try fetchAll().count, 1)
    }

    @MainActor
    func testInsertingDifferentContentCreatesSeparateItems() throws {
        let store = makeStore()

        store.insert(CapturedContent(kind: .text, text: "first"))
        store.insert(CapturedContent(kind: .text, text: "second"))

        XCTAssertEqual(try fetchAll().count, 2)
    }

    // MARK: - Pin / delete / clear

    @MainActor
    func testTogglePinFlipsState() throws {
        let store = makeStore()
        let item = try XCTUnwrap(store.insert(CapturedContent(kind: .text, text: "pin me")))

        XCTAssertFalse(item.isPinned)
        store.togglePin(item)
        XCTAssertTrue(item.isPinned)
        store.togglePin(item)
        XCTAssertFalse(item.isPinned)
    }

    @MainActor
    func testDeleteRemovesItem() throws {
        let store = makeStore()
        let item = try XCTUnwrap(store.insert(CapturedContent(kind: .text, text: "ephemeral")))

        store.delete(item)

        XCTAssertEqual(try fetchAll().count, 0)
    }

    @MainActor
    func testClearUnpinnedKeepsPinnedAndBoardedItems() throws {
        let store = makeStore()
        let pinned = try XCTUnwrap(store.insert(CapturedContent(kind: .text, text: "keep-pinned")))
        store.togglePin(pinned)
        let boarded = try XCTUnwrap(store.insert(CapturedContent(kind: .text, text: "keep-boarded")))
        let board = try XCTUnwrap(store.createPinboard(named: "Work"))
        store.assign(boarded, to: board)
        store.insert(CapturedContent(kind: .text, text: "drop-1"))
        store.insert(CapturedContent(kind: .text, text: "drop-2"))

        store.clearUnpinned()

        let remaining = try fetchAll()
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(Set(remaining.compactMap(\.text)), ["keep-pinned", "keep-boarded"])
    }

    // MARK: - History limit / prune gating

    @MainActor
    func testSaveAndPruneWithoutSyncedSettingsDeletesNothing() throws {
        let store = makeStore()
        let total = AppConstants.defaultHistoryLimit + 20
        let base = Date(timeIntervalSinceNow: -100_000)
        for index in 0..<total {
            let item = ClipItem(
                content: CapturedContent(kind: .text, text: "bulk-\(index)"),
                createdAt: base.addingTimeInterval(TimeInterval(index))
            )
            container.mainContext.insert(item)
        }

        // Far beyond the default limit, but no synced AppSettings record is
        // visible, so pruning must stay disabled (the data-loss review fix).
        try store.saveAndPrune()
        XCTAssertEqual(try fetchAll().count, total)

        // A regular insert on top still prunes nothing.
        store.insert(CapturedContent(kind: .text, text: "one-more"))
        XCTAssertEqual(try fetchAll().count, total + 1)
        XCTAssertFalse(store.hasSyncedHistoryLimit)
    }

    @MainActor
    func testSetHistoryLimitCreatesSyncedRecordAndWritesMirror() throws {
        let store = makeStore()
        XCTAssertEqual(store.historyLimit, AppConstants.defaultHistoryLimit)
        XCTAssertFalse(store.hasSyncedHistoryLimit)
        XCTAssertNil(store.syncedHistoryLimit())

        store.setHistoryLimit(25)

        XCTAssertTrue(store.hasSyncedHistoryLimit)
        XCTAssertEqual(store.syncedHistoryLimit(), 25)
        XCTAssertEqual(store.historyLimit, 25)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: AppConstants.historyLimitKey), 25)
        let settings = try XCTUnwrap(store.resolvedSettings())
        // Explicit user choice must carry a real updatedAt so it wins merges.
        XCTAssertGreaterThan(settings.updatedAt, .distantPast)
    }

    @MainActor
    func testSetHistoryLimitPrunesOldestAndProtectsPinnedAndBoarded() throws {
        let store = makeStore()
        let base = Date(timeIntervalSinceNow: -1_000)

        // Pinned and boarded items are the OLDEST, so pruning would take them
        // first if they were not protected.
        let pinned = try XCTUnwrap(store.insert(CapturedContent(kind: .text, text: "pinned")))
        pinned.createdAt = base.addingTimeInterval(-2)
        store.togglePin(pinned)

        let boarded = try XCTUnwrap(store.insert(CapturedContent(kind: .text, text: "boarded")))
        boarded.createdAt = base.addingTimeInterval(-1)
        let board = try XCTUnwrap(store.createPinboard(named: "Work"))
        store.assign(boarded, to: board)

        for index in 0..<5 {
            let item = try XCTUnwrap(store.insert(CapturedContent(kind: .text, text: "plain-\(index)")))
            item.createdAt = base.addingTimeInterval(TimeInterval(index))
        }

        store.setHistoryLimit(3)

        XCTAssertEqual(UserDefaults.standard.integer(forKey: AppConstants.historyLimitKey), 3)
        XCTAssertEqual(
            Set(try fetchAll().compactMap(\.text)),
            ["pinned", "boarded", "plain-2", "plain-3", "plain-4"]
        )

        // Subsequent inserts keep pruning: the new item is newest, so the
        // oldest remaining prunable item falls off.
        store.insert(CapturedContent(kind: .text, text: "newest"))
        XCTAssertEqual(
            Set(try fetchAll().compactMap(\.text)),
            ["pinned", "boarded", "plain-3", "plain-4", "newest"]
        )
    }

    // MARK: - noteLocalInsert auto-default

    @MainActor
    func testCrossingDefaultLimitOfLocalInsertsCreatesDefaultSettingsRecord() throws {
        UserDefaults.standard.set(
            AppConstants.defaultHistoryLimit - 1,
            forKey: Self.localInsertCountKey
        )
        let store = makeStore()

        // This insert brings the local count exactly TO the limit — not yet
        // crossed, so no record may appear.
        store.insert(CapturedContent(kind: .text, text: "reaches-limit"))
        XCTAssertNil(store.resolvedSettings())
        XCTAssertFalse(store.hasSyncedHistoryLimit)

        // This insert crosses the limit: the silent default record appears.
        store.insert(CapturedContent(kind: .text, text: "crosses-limit"))

        let records = try container.mainContext.fetch(FetchDescriptor<AppSettings>())
        XCTAssertEqual(records.count, 1)
        let settings = try XCTUnwrap(records.first)
        XCTAssertEqual(settings.historyLimitValue, AppConstants.defaultHistoryLimit)
        // Silent default uses .distantPast so any explicit choice wins merges.
        XCTAssertEqual(settings.updatedAt, .distantPast)
        XCTAssertEqual(store.syncedHistoryLimit(), AppConstants.defaultHistoryLimit)
    }
}
