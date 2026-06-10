import Foundation
import SwiftData
import XCTest

/// Covers `ClipStore.resolvedSettings()`: deterministic merging of duplicate
/// synced AppSettings records created by concurrent first-runs on multiple
/// devices. Survivor = oldest createdAt (tie: smallest dedupID); adopted value
/// = newest updatedAt, so explicit choices beat silent defaults.
final class ClipStoreSettingsTests: XCTestCase {
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
    private func fetchAllSettings() throws -> [AppSettings] {
        try container.mainContext.fetch(FetchDescriptor<AppSettings>())
    }

    @MainActor
    @discardableResult
    private func insertSettings(
        value: Int,
        updatedAt: Date,
        createdAt: Date,
        dedupID: UUID? = nil
    ) -> AppSettings {
        let settings = AppSettings(historyLimitValue: value, updatedAt: updatedAt)
        settings.createdAt = createdAt
        if let dedupID {
            settings.dedupID = dedupID
        }
        container.mainContext.insert(settings)
        return settings
    }

    // MARK: - Base cases

    @MainActor
    func testResolvedSettingsReturnsNilWhenNoRecordExists() {
        XCTAssertNil(makeStore().resolvedSettings())
    }

    @MainActor
    func testResolvedSettingsReturnsSingleRecordUntouched() throws {
        let store = makeStore()
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let only = insertSettings(
            value: 100,
            updatedAt: updatedAt,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        store.save()

        let resolved = try XCTUnwrap(store.resolvedSettings())

        XCTAssertEqual(resolved.persistentModelID, only.persistentModelID)
        XCTAssertEqual(resolved.historyLimitValue, 100)
        XCTAssertEqual(resolved.updatedAt, updatedAt)
        XCTAssertEqual(try fetchAllSettings().count, 1)
    }

    @MainActor
    func testZeroValueRecordMeansLimitStillUnset() throws {
        let store = makeStore()
        insertSettings(value: 0, updatedAt: .distantPast, createdAt: Date(timeIntervalSince1970: 1_000))
        store.save()

        // 0 means "unset": a record exists but pruning must stay disabled.
        XCTAssertNotNil(store.resolvedSettings())
        XCTAssertNil(store.syncedHistoryLimit())
        XCTAssertFalse(store.hasSyncedHistoryLimit)
        XCTAssertEqual(store.historyLimit, AppConstants.defaultHistoryLimit)
    }

    // MARK: - Two-record merge

    @MainActor
    func testMergeKeepsOldestRecordCarryingNewestValue() throws {
        let store = makeStore()
        let newerUpdate = Date(timeIntervalSince1970: 1_700_000_000)
        let primary = insertSettings(
            value: 100,
            updatedAt: Date(timeIntervalSince1970: 1_600_000_000),
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        insertSettings(
            value: 2_000,
            updatedAt: newerUpdate,
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        store.save()

        let resolved = try XCTUnwrap(store.resolvedSettings())

        // Survivor is the OLDER record, but it carries the NEWER value.
        XCTAssertEqual(resolved.persistentModelID, primary.persistentModelID)
        XCTAssertEqual(resolved.historyLimitValue, 2_000)
        XCTAssertEqual(resolved.updatedAt, newerUpdate)
        XCTAssertEqual(try fetchAllSettings().count, 1)
    }

    @MainActor
    func testExplicitChoiceOnOlderRecordBeatsNewerDefaultRecord() throws {
        let store = makeStore()
        let explicitDate = Date(timeIntervalSince1970: 1_700_000_000)
        let primary = insertSettings(
            value: 42,
            updatedAt: explicitDate,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        // A later device's silent default (.distantPast) must NOT win.
        insertSettings(
            value: AppConstants.defaultHistoryLimit,
            updatedAt: .distantPast,
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        store.save()

        let resolved = try XCTUnwrap(store.resolvedSettings())

        XCTAssertEqual(resolved.persistentModelID, primary.persistentModelID)
        XCTAssertEqual(resolved.historyLimitValue, 42)
        XCTAssertEqual(resolved.updatedAt, explicitDate)
        XCTAssertEqual(try fetchAllSettings().count, 1)
    }

    @MainActor
    func testExplicitChoiceOnNewerRecordBeatsOlderDefaultRecord() throws {
        let store = makeStore()
        let explicitDate = Date(timeIntervalSince1970: 1_700_000_000)
        // The OLDER record is a silent default; the NEWER one is explicit.
        let primary = insertSettings(
            value: AppConstants.defaultHistoryLimit,
            updatedAt: .distantPast,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        insertSettings(
            value: 42,
            updatedAt: explicitDate,
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        store.save()

        let resolved = try XCTUnwrap(store.resolvedSettings())

        // Survivor identity is still the oldest record, value is the explicit one.
        XCTAssertEqual(resolved.persistentModelID, primary.persistentModelID)
        XCTAssertEqual(resolved.historyLimitValue, 42)
        XCTAssertEqual(resolved.updatedAt, explicitDate)
        XCTAssertEqual(try fetchAllSettings().count, 1)
    }

    @MainActor
    func testCreatedAtTieBreaksOnSmallestDedupID() throws {
        let store = makeStore()
        let sharedCreation = Date(timeIntervalSince1970: 1_000)
        let lowID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let highID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let expected = insertSettings(
            value: 100,
            updatedAt: .distantPast,
            createdAt: sharedCreation,
            dedupID: lowID
        )
        insertSettings(
            value: 200,
            updatedAt: .distantPast,
            createdAt: sharedCreation,
            dedupID: highID
        )
        store.save()

        let resolved = try XCTUnwrap(store.resolvedSettings())

        XCTAssertEqual(resolved.persistentModelID, expected.persistentModelID)
        // Equal updatedAt: the primary keeps its own value.
        XCTAssertEqual(resolved.historyLimitValue, 100)
        XCTAssertEqual(try fetchAllSettings().count, 1)
    }
}
