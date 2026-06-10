import Foundation
import SwiftData
import XCTest

final class ClipSearchTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try ModelContainerFactory.makeInMemory()
    }

    override func tearDown() async throws {
        container = nil
    }

    // MARK: - Helpers

    @MainActor
    @discardableResult
    private func insertItem(
        kind: ClipKind = .text,
        text: String? = nil,
        imageData: Data? = nil,
        fileName: String? = nil,
        sourceAppName: String? = nil
    ) -> ClipItem {
        let content = CapturedContent(
            kind: kind,
            text: text,
            imageData: imageData,
            fileName: fileName,
            sourceAppName: sourceAppName
        )
        let item = ClipItem(content: content)
        container.mainContext.insert(item)
        return item
    }

    // MARK: - Empty query

    @MainActor
    func testEmptyQueryMatchesAll() {
        let textItem = insertItem(text: "hello")
        let imageItem = insertItem(kind: .image, imageData: Data([0xFF]))

        XCTAssertTrue(ClipSearch.matches(item: textItem, query: ""))
        XCTAssertTrue(ClipSearch.matches(item: imageItem, query: ""))
        // Whitespace-only queries produce no tokens and also match everything.
        XCTAssertTrue(ClipSearch.matches(item: textItem, query: "   \n\t"))
        XCTAssertEqual(ClipSearch.filter(items: [textItem, imageItem], query: "").count, 2)
        XCTAssertEqual(ClipSearch.filter(items: [textItem, imageItem], query: "   ").count, 2)
    }

    // MARK: - Case and diacritic insensitivity

    @MainActor
    func testMatchingIsCaseInsensitive() {
        let item = insertItem(text: "Hello World")

        XCTAssertTrue(ClipSearch.matches(item: item, query: "hello"))
        XCTAssertTrue(ClipSearch.matches(item: item, query: "WORLD"))
        XCTAssertTrue(ClipSearch.matches(item: item, query: "hELLo wOrLd"))
    }

    @MainActor
    func testMatchingIsDiacriticInsensitive() {
        let accented = insertItem(text: "café au lait")
        let plain = insertItem(text: "cafe menu")

        XCTAssertTrue(ClipSearch.matches(item: accented, query: "cafe"))
        XCTAssertTrue(ClipSearch.matches(item: plain, query: "café"))
    }

    // MARK: - Multi-token AND semantics

    @MainActor
    func testMultiTokenRequiresEveryTokenAcrossFields() {
        // Token 1 matches the text, token 2 matches the source app name.
        let item = insertItem(text: "quarterly report", sourceAppName: "Safari")

        XCTAssertTrue(ClipSearch.matches(item: item, query: "report safari"))
        XCTAssertTrue(ClipSearch.matches(item: item, query: "safari quarterly"))
        // One matching token is not enough: every token must match somewhere.
        XCTAssertFalse(ClipSearch.matches(item: item, query: "report chrome"))
        XCTAssertFalse(ClipSearch.matches(item: item, query: "budget safari"))
    }

    // MARK: - Kind display name

    @MainActor
    func testKindDisplayNameMatchesURLItems() {
        let urlItem = insertItem(kind: .url, text: "https://example.com/docs")
        let textItem = insertItem(text: "plain note")
        let imageItem = insertItem(kind: .image, imageData: Data([0xFF]))

        XCTAssertTrue(ClipSearch.matches(item: urlItem, query: "Link"))
        XCTAssertTrue(ClipSearch.matches(item: urlItem, query: "link"))
        XCTAssertTrue(ClipSearch.matches(item: imageItem, query: "image"))
        XCTAssertFalse(ClipSearch.matches(item: textItem, query: "link"))

        let filtered = ClipSearch.filter(items: [urlItem, textItem, imageItem], query: "link")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.kind, .url)
    }

    // MARK: - File name field

    @MainActor
    func testFileNameFieldIsSearched() {
        let item = insertItem(kind: .file, fileName: "Budget2026.xlsx")

        XCTAssertTrue(ClipSearch.matches(item: item, query: "budget"))
        XCTAssertFalse(ClipSearch.matches(item: item, query: "invoice"))
    }

    // MARK: - Exclusion

    @MainActor
    func testNonMatchingItemsAreExcludedFromFilter() {
        let matching = insertItem(text: "swift concurrency notes")
        let other = insertItem(text: "grocery list")

        let filtered = ClipSearch.filter(items: [matching, other], query: "swift")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.text, "swift concurrency notes")

        XCTAssertTrue(ClipSearch.filter(items: [matching, other], query: "zzz-no-match").isEmpty)
    }
}
