import Foundation
import XCTest

final class ContentHasherTests: XCTestCase {

    // MARK: - Determinism

    func testSameInputProducesSameHash() {
        let imageData = Data([0x01, 0x02, 0x03])
        let first = ContentHasher.hash(kind: .image, text: "caption", imageData: imageData, fileName: "photo.png")
        let second = ContentHasher.hash(kind: .image, text: "caption", imageData: imageData, fileName: "photo.png")
        XCTAssertEqual(first, second)
    }

    func testHashIsLowercaseHexOf64Characters() {
        let hash = ContentHasher.hash(kind: .text, text: "hello", imageData: nil, fileName: nil)
        XCTAssertEqual(hash.count, 64)
        XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testCapturedContentHashMatchesContentHasher() {
        let content = CapturedContent(kind: .file, fileName: "report.pdf", sourceAppName: "Finder")
        // sourceAppName must not influence the hash; only user-visible content does.
        XCTAssertEqual(
            content.contentHash,
            ContentHasher.hash(kind: .file, text: nil, imageData: nil, fileName: "report.pdf")
        )
    }

    // MARK: - Field sensitivity

    func testDifferentKindProducesDifferentHash() {
        let asText = ContentHasher.hash(kind: .text, text: "https://example.com", imageData: nil, fileName: nil)
        let asURL = ContentHasher.hash(kind: .url, text: "https://example.com", imageData: nil, fileName: nil)
        XCTAssertNotEqual(asText, asURL)
    }

    func testDifferentTextProducesDifferentHash() {
        let first = ContentHasher.hash(kind: .text, text: "alpha", imageData: nil, fileName: nil)
        let second = ContentHasher.hash(kind: .text, text: "beta", imageData: nil, fileName: nil)
        XCTAssertNotEqual(first, second)
    }

    func testDifferentImageDataProducesDifferentHash() {
        let first = ContentHasher.hash(kind: .image, text: nil, imageData: Data([0x00]), fileName: nil)
        let second = ContentHasher.hash(kind: .image, text: nil, imageData: Data([0x01]), fileName: nil)
        XCTAssertNotEqual(first, second)
    }

    func testDifferentFileNameProducesDifferentHash() {
        let first = ContentHasher.hash(kind: .file, text: nil, imageData: nil, fileName: "a.txt")
        let second = ContentHasher.hash(kind: .file, text: nil, imageData: nil, fileName: "b.txt")
        XCTAssertNotEqual(first, second)
    }

    // MARK: - nil vs. empty (documented collision)

    func testNilAndEmptyTextProduceSameHash() {
        // Actual behavior: a nil field skips the hasher update and an empty
        // string contributes zero bytes, so the two collide by design and
        // de-duplication treats them as identical content.
        let nilText = ContentHasher.hash(kind: .text, text: nil, imageData: nil, fileName: nil)
        let emptyText = ContentHasher.hash(kind: .text, text: "", imageData: nil, fileName: nil)
        XCTAssertEqual(nilText, emptyText)
    }

    func testNilAndEmptyFileNameProduceSameHash() {
        let nilName = ContentHasher.hash(kind: .file, text: nil, imageData: nil, fileName: nil)
        let emptyName = ContentHasher.hash(kind: .file, text: nil, imageData: nil, fileName: "")
        XCTAssertEqual(nilName, emptyName)
    }

    // MARK: - Separator bytes prevent cross-field bleed

    func testTextDoesNotBleedIntoFileName() {
        let joined = ContentHasher.hash(kind: .text, text: "ab", imageData: nil, fileName: nil)
        let split = ContentHasher.hash(kind: .text, text: "a", imageData: nil, fileName: "b")
        XCTAssertNotEqual(joined, split)
    }

    func testTextDoesNotBleedIntoImageData() {
        let asText = ContentHasher.hash(kind: .text, text: "abc", imageData: nil, fileName: nil)
        let asImage = ContentHasher.hash(kind: .text, text: nil, imageData: Data("abc".utf8), fileName: nil)
        XCTAssertNotEqual(asText, asImage)
    }

    func testImageDataDoesNotBleedIntoFileName() {
        let joined = ContentHasher.hash(kind: .file, text: nil, imageData: Data("ab".utf8), fileName: nil)
        let split = ContentHasher.hash(kind: .file, text: nil, imageData: Data("a".utf8), fileName: "b")
        XCTAssertNotEqual(joined, split)
    }
}
