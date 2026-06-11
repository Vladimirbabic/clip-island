import Foundation
import XCTest

final class OpenGraphParserTests: XCTestCase {
    private let base = URL(string: "https://example.com/article")!

    func testFindsOGImagePropertyFirst() {
        let html = #"""
        <head>
        <meta property="og:title" content="Hello">
        <meta property="og:image" content="https://cdn.example.com/hero.jpg">
        </head>
        """#
        XCTAssertEqual(
            OpenGraphParser.imageURL(inHTML: html, baseURL: base)?.absoluteString,
            "https://cdn.example.com/hero.jpg"
        )
    }

    func testFindsImageWithReversedAttributeOrder() {
        let html = #"<meta content="https://cdn.example.com/rev.png" property="og:image">"#
        XCTAssertEqual(
            OpenGraphParser.imageURL(inHTML: html, baseURL: base)?.absoluteString,
            "https://cdn.example.com/rev.png"
        )
    }

    func testFallsBackToTwitterImage() {
        let html = #"<meta name="twitter:image" content="https://cdn.example.com/tw.png">"#
        XCTAssertEqual(
            OpenGraphParser.imageURL(inHTML: html, baseURL: base)?.absoluteString,
            "https://cdn.example.com/tw.png"
        )
    }

    func testResolvesRelativeURLAgainstBase() {
        let html = #"<meta property="og:image" content="/assets/hero.jpg">"#
        XCTAssertEqual(
            OpenGraphParser.imageURL(inHTML: html, baseURL: base)?.absoluteString,
            "https://example.com/assets/hero.jpg"
        )
    }

    func testDecodesAmpersandEntities() {
        let html = #"<meta property="og:image" content="https://cdn.example.com/i.png?a=1&amp;b=2">"#
        XCTAssertEqual(
            OpenGraphParser.imageURL(inHTML: html, baseURL: base)?.absoluteString,
            "https://cdn.example.com/i.png?a=1&b=2"
        )
    }

    func testIsCaseInsensitive() {
        let html = #"<META PROPERTY="OG:IMAGE" CONTENT="https://cdn.example.com/up.png">"#
        XCTAssertEqual(
            OpenGraphParser.imageURL(inHTML: html, baseURL: base)?.absoluteString,
            "https://cdn.example.com/up.png"
        )
    }

    func testReturnsNilWithoutImageMeta() {
        XCTAssertNil(OpenGraphParser.imageURL(inHTML: "<head><title>x</title></head>", baseURL: base))
        XCTAssertNil(OpenGraphParser.imageURL(inHTML: "", baseURL: base))
    }
}
