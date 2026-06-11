import CryptoKit
import Foundation

/// Password helper for locked pinboards. This is a UI privacy lock: it hides
/// page contents until a password is entered, but it does not encrypt existing
/// persisted clip rows.
enum PinboardLocking {
    static let minimumPasswordLength = 4

    private static let domain = "clipstory.pinboard.lock.v1"
    private static let iterations = 25_000

    static func makeCredentials(password: String) -> (salt: String, hash: String) {
        let salt = "\(UUID().uuidString)-\(UUID().uuidString)"
        return (salt, hash(password: password, salt: salt))
    }

    static func verify(password: String, salt: String, expectedHash: String) -> Bool {
        guard !salt.isEmpty, !expectedHash.isEmpty else { return false }
        return constantTimeEqual(hash(password: password, salt: salt), expectedHash)
    }

    private static func hash(password: String, salt: String) -> String {
        var digest = SHA256.hash(data: Data("\(domain):\(salt):\(password)".utf8))
        let saltData = Data(salt.utf8)
        for _ in 0..<iterations {
            var hasher = SHA256()
            hasher.update(data: Data(digest))
            hasher.update(data: saltData)
            digest = hasher.finalize()
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        return zip(lhsBytes, rhsBytes).reduce(UInt8(0)) { result, pair in
            result | (pair.0 ^ pair.1)
        } == 0
    }
}
