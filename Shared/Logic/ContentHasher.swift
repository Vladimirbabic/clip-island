import CryptoKit
import Foundation

/// Pure hashing helpers for clipboard content de-duplication.
enum ContentHasher {
    static func hash(kind: ClipKind, text: String?, imageData: Data?, fileName: String?) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: Data([0x1F]))
        if let text {
            hasher.update(data: Data(text.utf8))
        }
        hasher.update(data: Data([0x1F]))
        if let imageData {
            hasher.update(data: imageData)
        }
        hasher.update(data: Data([0x1F]))
        if let fileName {
            hasher.update(data: Data(fileName.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
