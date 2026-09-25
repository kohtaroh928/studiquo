import XCTest
import SwiftData
@testable import studiquo

/// Regression coverage for two, opposite bugs this token's lifecycle has
/// had: originally it never rotated at all even once the server started
/// rejecting it as expired, and a later fix for that over-corrected by
/// silently minting a replacement the server had never seen (see
/// loadOrCreateToken's own doc comment in ContentView.swift for the full
/// story, and .studiquoAuthFailed in AuthenticationStore.swift for how a
/// real 401 is handled instead now).
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

    /// Regression test for a real report: a device would go on to silently
    /// mint its own replacement token here once the stored one looked
    /// locally expired — a token the server's mintSession had never
    /// recorded a session for, so `isExpired` on the *new* token said "not
    /// expired" while every actual request still came back 401 "no
    /// session", shown to the user as a misleading "login expired" message
    /// even though nothing about their login had really expired. Only a
    /// real sign-in (see AuthenticationStore) can produce a token the
    /// server actually recognizes, so loadOrCreateToken must leave a
    /// locally-expired-looking token alone and let the server's own 401 be
    /// what triggers re-authentication.
    func testLoadOrCreateTokenDoesNotSilentlyRotateAnExpiredStoredToken() {
        let ninetyOneDays: TimeInterval = 91 * 24 * 60 * 60
        let expired = token(issuedSecondsAgo: ninetyOneDays)
        MCPCloudCredentials.save(expired)

        XCTAssertEqual(MCPCloudCredentials.loadOrCreateToken(), expired)
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

final class MCPImportReceiptTests: XCTestCase {
    @MainActor
    func testImportedDocumentAndReceiptSurviveReloadTogether() throws {
        let configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true,
                                               cloudKitDatabase: .none)
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        let context = ModelContext(container)
        context.insert(TextDocument(title: "Claudeからの資料"))
        context.insert(MCPImportReceipt(id: "request-1", title: "Claudeからの資料",
                                        kind: "create_document", source: "Claude"))
        try context.save()

        let reloaded = ModelContext(container)
        let receipts = try reloaded.fetch(FetchDescriptor<MCPImportReceipt>())
        let documents = try reloaded.fetch(FetchDescriptor<TextDocument>())
        XCTAssertEqual(receipts.map(\.id), ["request-1"])
        XCTAssertEqual(documents.filter { $0.title == "Claudeからの資料" }.count, 1)
    }
}
