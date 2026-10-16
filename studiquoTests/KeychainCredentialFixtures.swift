import Security
import XCTest
@testable import studiquo

/// Shared Keychain test fixture for tests that need an `AuthenticationStore`
/// that's already signed in, without driving a real (network-dependent)
/// sign-in flow. Password verification and account creation both happen
/// server-side now (see local-auth.js / mcp-server), so there is no local
/// credential record left to seed — a signed-in device is just an
/// "oauth-identity" record (the same one login()/loginWithApple()/etc. all
/// write), a live local "session" record, and an unexpired server-issued
/// cloud token. The token is a separate Keychain item because the Worker,
/// rather than the local session record, is authoritative for cloud access.
enum KeychainCredentialFixtures {
    /// Writes the local Keychain items `AuthenticationStore.restore()` checks
    /// for, so a freshly constructed store for `service` starts out signed
    /// in (state `.authenticated` or `.onboarding`) exactly as if `email` had
    /// just logged in via email/password.
    static func seedSignedInDevice(
        service: String, email: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        writeJSONItem(
            service: service, account: "oauth-identity",
            json: ["provider": "email", "subject": email, "email": email],
            file: file, line: line
        )
        MCPCloudCredentials.save("\(Int(Date().timeIntervalSince1970)).\(String(repeating: "t", count: 64))")
        let expiresAt = Date().addingTimeInterval(6 * 30 * 24 * 60 * 60)
        writeJSONItem(
            service: service, account: "session",
            // `Date`'s default Codable conformance (which plain `JSONEncoder()`
            // uses, since AuthenticationStore sets no dateEncodingStrategy)
            // encodes as a single Double of timeIntervalSinceReferenceDate —
            // not since-1970 and not ISO 8601 — so this fixture must match it
            // exactly, or SessionRecord silently fails to decode.
            json: ["token": UUID().uuidString, "expiresAt": expiresAt.timeIntervalSinceReferenceDate],
            file: file, line: line
        )
    }

    static func seedAllAccountCredentials(service: String, email: String) {
        seedSignedInDevice(service: service, email: email)
        writeJSONItem(service: service, account: "passkey-identity", json: ["email": email], file: #filePath, line: #line)
    }

    static func containsItem(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private static func writeJSONItem(
        service: String, account: String, json: [String: Any],
        file: StaticString, line: UInt
    ) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess, file: file, line: line)
    }
}
