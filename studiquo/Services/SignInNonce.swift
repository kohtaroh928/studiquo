import CryptoKit
import Foundation

/// A nonce ties a Sign in with Apple / Google ID token to the ONE sign-in this app
/// started. Without it, the server can tell that an ID token is genuine, but not that
/// it was made for this sign-in: a copy taken from the device or its traffic could be
/// sent again by someone else and would be accepted until it expired.
///
/// - `raw` stays on the device and goes only to our own server (over TLS).
/// - `hashed` (SHA-256, lower-case hex) is what Apple / Google put in the ID token's
///   `nonce` claim. The server hashes `raw` and compares it with that claim, and
///   accepts each nonce once (mcp-server/src/id-token-nonce.js).
struct SignInNonce: Equatable, Sendable {
    let raw: String
    let hashed: String

    /// 32 random bytes from the system's secure random source, as 64 hex characters.
    static func make() -> SignInNonce {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Not expected. Fall back to Swift's system-seeded generator rather than
            // send a weak or empty value.
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
        }
        let raw = bytes.map { String(format: "%02x", $0) }.joined()
        return SignInNonce(raw: raw, hashed: sha256Hex(raw))
    }

    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Holds the nonce of the sign-in that is in progress, between the moment the request
/// is made (SwiftUI's button builds it in its own closure) and the moment its result
/// comes back. Safe to use from any thread.
final class PendingSignInNonce: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SignInNonce?

    func store(_ nonce: SignInNonce) { lock.lock(); value = nonce; lock.unlock() }

    /// The stored nonce, which is forgotten as it is taken: one sign-in, one nonce.
    func take() -> SignInNonce? { lock.lock(); defer { lock.unlock() }; let taken = value; value = nil; return taken }
}
