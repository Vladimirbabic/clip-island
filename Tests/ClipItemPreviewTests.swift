import Foundation
import XCTest

/// Card text semantics: the custom title is a NAME shown in the card header;
/// the body must always summarize the actual content that pasting produces.
final class ClipItemPreviewTests: XCTestCase {
    private func makeTextItem(_ text: String) -> ClipItem {
        ClipItem(content: CapturedContent(kind: .text, text: text))
    }

    func testCardTitleUsesCustomTitleWhenSet() {
        let item = makeTextItem("actual snippet body")
        item.customTitle = "My Snippet"
        XCTAssertEqual(item.cardTitle, "My Snippet")
    }

    func testCardTitleFallsBackToKindName() {
        let item = makeTextItem("actual snippet body")
        XCTAssertEqual(item.cardTitle, ClipKind.text.displayName)

        item.customTitle = "   "
        XCTAssertEqual(item.cardTitle, ClipKind.text.displayName)
    }

    func testContentPreviewIgnoresCustomTitle() {
        let item = makeTextItem("actual snippet body")
        item.customTitle = "My Snippet"
        XCTAssertEqual(item.contentPreview, "actual snippet body")
    }

    func testPreviewStillPrefersCustomTitleForLists() {
        let item = makeTextItem("actual snippet body")
        item.customTitle = "My Snippet"
        XCTAssertEqual(item.preview, "My Snippet")
    }
}
