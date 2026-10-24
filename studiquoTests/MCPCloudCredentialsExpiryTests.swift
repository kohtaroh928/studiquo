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

/// A person who keeps using the app must not be signed out when the token's 90
/// days end: an old-enough token is exchanged for a new one, and any failure
/// leaves the stored token exactly as it was.
final class MCPCloudCredentialsRefreshTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MCPCloudCredentials.clear()
        RefreshStubProtocol.reset()
    }

    override func tearDown() {
        MCPCloudCredentials.clear()
        RefreshStubProtocol.reset()
        super.tearDown()
    }

    private func token(issuedDaysAgo days: Double, tail: String = "deadbeef") -> String {
        "\(Int(Date().timeIntervalSince1970 - days * 86_400))." + String(repeating: tail, count: 4)
    }

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testATokenOlderThanThirtyDaysIsReplacedByTheOneTheServerGives() async {
        let old = token(issuedDaysAgo: 45)
        let replacement = token(issuedDaysAgo: 0, tail: "cafef00d")
        MCPCloudCredentials.save(old)
        RefreshStubProtocol.respond(status: 200, json: ["refreshed": true, "token": replacement])

        await MCPCloudCredentials.refreshIfNeeded(session: session)

        XCTAssertEqual(MCPCloudCredentials.currentToken(), replacement)
        XCTAssertEqual(RefreshStubProtocol.lastRequest?.url?.path, "/api/session/refresh")
        XCTAssertEqual(RefreshStubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer \(old)")
    }

    func testARecentTokenIsNotSentToTheServerAtAll() async {
        let recent = token(issuedDaysAgo: 5)
        MCPCloudCredentials.save(recent)

        await MCPCloudCredentials.refreshIfNeeded(session: session)

        XCTAssertNil(RefreshStubProtocol.lastRequest)
        XCTAssertEqual(MCPCloudCredentials.currentToken(), recent)
    }

    func testAnAlreadyExpiredTokenIsLeftForTheNormalSignInPath() async {
        let expired = token(issuedDaysAgo: 100)
        MCPCloudCredentials.save(expired)

        await MCPCloudCredentials.refreshIfNeeded(session: session)

        XCTAssertNil(RefreshStubProtocol.lastRequest)
        XCTAssertEqual(MCPCloudCredentials.currentToken(), expired)
    }

    func testAServerFailureKeepsTheStoredToken() async {
        let old = token(issuedDaysAgo: 45)
        MCPCloudCredentials.save(old)
        for status in [401, 404, 500] {
            RefreshStubProtocol.respond(status: status, json: ["error": "no"])
            await MCPCloudCredentials.refreshIfNeeded(session: session)
            XCTAssertEqual(MCPCloudCredentials.currentToken(), old, "status \(status)")
        }
    }

    func testAReplacementThatIsUnusableIsNotStored() async {
        let old = token(issuedDaysAgo: 45)
        MCPCloudCredentials.save(old)
        for body: [String: Any] in [
            ["refreshed": false],
            ["refreshed": true],
            ["refreshed": true, "token": "short"],
            ["refreshed": true, "token": token(issuedDaysAgo: 100, tail: "cafef00d")],
        ] {
            RefreshStubProtocol.respond(status: 200, json: body)
            await MCPCloudCredentials.refreshIfNeeded(session: session)
            XCTAssertEqual(MCPCloudCredentials.currentToken(), old, "\(body)")
        }
    }

    func testSigningOutWhileTheRequestIsInFlightDoesNotBringTheTokenBack() async {
        let old = token(issuedDaysAgo: 45)
        MCPCloudCredentials.save(old)
        RefreshStubProtocol.respond(status: 200, json: ["refreshed": true, "token": token(issuedDaysAgo: 0, tail: "cafef00d")])
        RefreshStubProtocol.onRequest = { MCPCloudCredentials.clear() }

        await MCPCloudCredentials.refreshIfNeeded(session: session)

        XCTAssertNil(MCPCloudCredentials.currentToken())
    }

    func testALockedKeychainNeverProducesAReplacementToken() {
        let stored = String(repeating: "a", count: 40)
        XCTAssertEqual(MCPCloudCredentials.tokenDecision(token: nil, status: errSecInteractionNotAllowed), .unavailable)
        XCTAssertEqual(MCPCloudCredentials.tokenDecision(token: "short", status: errSecInteractionNotAllowed), .unavailable)
        XCTAssertEqual(MCPCloudCredentials.tokenDecision(token: nil, status: errSecItemNotFound), .createNew)
        XCTAssertEqual(MCPCloudCredentials.tokenDecision(token: "short", status: errSecSuccess), .createNew)
        XCTAssertEqual(MCPCloudCredentials.tokenDecision(token: stored, status: errSecSuccess), .use(stored))
        XCTAssertTrue(MCPCloudCredentials.isLocked(status: errSecInteractionNotAllowed))
        XCTAssertFalse(MCPCloudCredentials.isLocked(status: errSecItemNotFound))
        XCTAssertFalse(MCPCloudCredentials.isLocked(status: errSecSuccess))
    }

    func testARequestSentWithoutATokenKeepsAuthFailuresFromSigningOutForAWhile() {
        _ = MCPCloudCredentials.tokenDecision(token: nil, status: errSecInteractionNotAllowed)
        // tokenDecision is pure; only loadOrCreateToken records the lock.
        XCTAssertFalse(MCPCloudCredentials.sentWithoutTokenRecently(now: Date().addingTimeInterval(10_000)))
    }

    func testSavingOverAnExistingTokenReplacesItInPlace() {
        MCPCloudCredentials.save(token(issuedDaysAgo: 1, tail: "aaaaaaaa"))
        let next = token(issuedDaysAgo: 0, tail: "bbbbbbbb")
        MCPCloudCredentials.save(next)
        XCTAssertEqual(MCPCloudCredentials.currentToken(), next)
    }

    func testAReadableKeychainIsNotReportedAsUnavailable() {
        XCTAssertFalse(MCPCloudCredentials.isStorageUnavailable, "no token stored")
        MCPCloudCredentials.save(token(issuedDaysAgo: 1))
        XCTAssertFalse(MCPCloudCredentials.isStorageUnavailable, "token stored")
    }
}

private final class RefreshStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var status = 200
    private static var data = Data()
    private static var request: URLRequest?
    nonisolated(unsafe) static var onRequest: (() -> Void)?

    static var lastRequest: URLRequest? { lock.lock(); defer { lock.unlock() }; return request }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        status = 200; data = Data(); request = nil; onRequest = nil
    }

    static func respond(status: Int, json: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        self.data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.request = request
        let status = Self.status, data = Self.data, hook = Self.onRequest
        Self.lock.unlock()
        hook?()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class PasskeyReauthDetectionTests: XCTestCase {
    private func body(_ code: String) -> Data { try! JSONSerialization.data(withJSONObject: ["error": "x", "code": code]) }

    func testOnlyA403WithTheReauthCodeCountsAsNeedingAPasskeyCheck() {
        XCTAssertTrue(PasskeyReauth.isRequired(status: 403, body: body("reauth_required")))
        XCTAssertFalse(PasskeyReauth.isRequired(status: 403, body: body("passkey_required")))
        XCTAssertFalse(PasskeyReauth.isRequired(status: 401, body: body("reauth_required")))
        XCTAssertFalse(PasskeyReauth.isRequired(status: 403, body: Data("not json".utf8)))
        XCTAssertFalse(PasskeyReauth.isRequired(status: nil, body: Data()))
    }

    func testThePasskeyRequiredAnswerIsRecognised() {
        XCTAssertTrue(PasskeyRequired.isIn(body: body("passkey_required")))
        XCTAssertFalse(PasskeyRequired.isIn(body: body("reauth_required")))
    }

    func testTheAccountDeletingAnswerIsRecognisedAndIsNotMistakenForAPasskeyOne() {
        XCTAssertTrue(AccountDeleting.isIn(body: body("account_deleting")))
        XCTAssertFalse(AccountDeleting.isIn(body: body("passkey_required")))
        XCTAssertFalse(PasskeyRequired.isIn(body: body("account_deleting")))
        XCTAssertFalse(AccountDeleting.isIn(body: Data("not json".utf8)))
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
