import XCTest
@testable import studiquo

/// Regression coverage for "the cloud sync Bearer token never expires".
final class MCPCloudCredentialsExpiryTests: XCTestCase {
    override func tearDown() {
        MCPCloudCredentials.clear()
        super.tearDown()
    }

    private func token(issuedSecondsAgo seconds: TimeInterval) -> String {
        let issuedAt = Int(Date().timeIntervalSince1970 - seconds)
        return "\(issuedAt)." + String(repeating: "deadbeef", count: 4)
    }

    func testFreshlyCreatedTokenIsNotExpired() {
        MCPCloudCredentials.clear()
        let token = MCPCloudCredentials.loadOrCreateToken()
        XCTAssertFalse(MCPCloudCredentials.isExpired(token))
    }

    func testTokenJustUnderNinetyDaysOldIsNotExpired() {
        let eightyNineDays: TimeInterval = 89 * 24 * 60 * 60
        XCTAssertFalse(MCPCloudCredentials.isExpired(token(issuedSecondsAgo: eightyNineDays)))
    }

    func testTokenOlderThanNinetyDaysIsExpired() {
        let ninetyOneDays: TimeInterval = 91 * 24 * 60 * 60
        XCTAssertTrue(MCPCloudCredentials.isExpired(token(issuedSecondsAgo: ninetyOneDays)))
    }

    func testTokenWithoutAnEmbeddedIssueDateIsTreatedAsExpired() {
        XCTAssertTrue(MCPCloudCredentials.isExpired("plain-legacy-token-with-no-dot"))
    }

    func testLoadOrCreateTokenRotatesAnExpiredStoredToken() {
        let ninetyOneDays: TimeInterval = 91 * 24 * 60 * 60
        let expired = token(issuedSecondsAgo: ninetyOneDays)
        MCPCloudCredentials.save(expired)

        let refreshed = MCPCloudCredentials.loadOrCreateToken()

        XCTAssertNotEqual(refreshed, expired)
        XCTAssertFalse(MCPCloudCredentials.isExpired(refreshed))
    }

    func testLoadOrCreateTokenKeepsAnUnexpiredStoredToken() {
        let tenDays: TimeInterval = 10 * 24 * 60 * 60
        let stillValid = token(issuedSecondsAgo: tenDays)
        MCPCloudCredentials.save(stillValid)

        XCTAssertEqual(MCPCloudCredentials.loadOrCreateToken(), stillValid)
    }

    /// Regression test for a bug caught during manual verification: the
    /// Settings screen's "generate a new token" button used to build its own
    /// plain UUID string instead of going through `generateAndSaveNewToken()`,
    /// so a manually regenerated token had no issue date and the server
    /// rejected it as expired immediately.
    func testGenerateAndSaveNewTokenProducesAnUnexpiredToken() {
        let token = MCPCloudCredentials.generateAndSaveNewToken()
        XCTAssertFalse(MCPCloudCredentials.isExpired(token))
        XCTAssertEqual(MCPCloudCredentials.currentToken(), token)
    }
}
