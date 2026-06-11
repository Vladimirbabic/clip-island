import Foundation
import SwiftData
import XCTest

/// Covers the synced per-app brand (header color + icon) that keeps card
/// styling identical across macOS and iOS. Only Macs can resolve app icons,
/// so they publish SourceAppBrand records; iOS renders from them.
final class SourceAppBrandTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try ModelContainerFactory.makeInMemory()
    }

    override func tearDown() async throws {
        container = nil
    }

    @MainActor
    private func makeStore() -> ClipStore {
        ClipStore(container: container)
    }

    // MARK: - Upsert

    @MainActor
    func testUpsertCreatesThenUpdatesSingleRecord() throws {
        let store = makeStore()
        store.upsertBrand(bundleID: "com.apple.Safari", appName: "Safari", colorHex: "1F7AF5", iconPNG: Data([1]))
        store.upsertBrand(bundleID: "com.apple.Safari", appName: "Safari", colorHex: "2080FF", iconPNG: Data([2]))

        let all = try container.mainContext.fetch(FetchDescriptor<SourceAppBrand>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.colorHex, "2080FF")
        XCTAssertEqual(all.first?.iconPNG, Data([2]))
    }

    @MainActor
    func testUpsertIgnoresEmptyBundleID() throws {
        let store = makeStore()
        store.upsertBrand(bundleID: "", appName: nil, colorHex: "FFFFFF", iconPNG: nil)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<SourceAppBrand>()).count, 0)
    }

    // MARK: - Cross-device duplicate merge

    @MainActor
    func testBrandsByBundleIDMergesDuplicatesDeterministically() throws {
        let context = container.mainContext
        let older = SourceAppBrand(bundleID: "com.google.Chrome")
        older.colorHex = "AAAAAA"
        older.updatedAt = Date(timeIntervalSince1970: 1_000)
        let newer = SourceAppBrand(bundleID: "com.google.Chrome")
        newer.colorHex = "BBBBBB"
        newer.updatedAt = Date(timeIntervalSince1970: 2_000)
        context.insert(older)
        context.insert(newer)
        try context.save()

        let store = makeStore()
        let brands = store.brandsByBundleID()

        // Newest updatedAt wins; duplicates are physically merged away.
        XCTAssertEqual(brands["com.google.Chrome"]?.colorHex, "BBBBBB")
        XCTAssertEqual(try context.fetch(FetchDescriptor<SourceAppBrand>()).count, 1)
    }

    // MARK: - Shared fallback palette

    func testFallbackPaletteIsDeterministicAcrossCalls() {
        let first = AppBrandPalette.fallbackIndex(forSeed: "com.example.app")
        let second = AppBrandPalette.fallbackIndex(forSeed: "com.example.app")
        XCTAssertEqual(first, second)
        XCTAssertTrue((0..<AppBrandPalette.fallback.count).contains(first))
    }

    func testHexRoundTrip() {
        let hex = AppBrandPalette.hex(red: 0.91, green: 0.12, blue: 0.81)
        let components = AppBrandPalette.components(fromHex: hex)
        XCTAssertNotNil(components)
        XCTAssertEqual(components!.red, 0.91, accuracy: 0.01)
        XCTAssertEqual(components!.green, 0.12, accuracy: 0.01)
        XCTAssertEqual(components!.blue, 0.81, accuracy: 0.01)
    }

    func testComponentsRejectsMalformedHex() {
        XCTAssertNil(AppBrandPalette.components(fromHex: ""))
        XCTAssertNil(AppBrandPalette.components(fromHex: "ZZZZZZ"))
        XCTAssertNil(AppBrandPalette.components(fromHex: "FFF"))
    }
}
