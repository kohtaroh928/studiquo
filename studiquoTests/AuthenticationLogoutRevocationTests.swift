import XCTest
@testable import studiquo

/// Regression coverage for "logging out doesn't revoke the cloud sync token".
/// Exercises `AuthenticationStore.logout()` end to end against a stubbed
/// network so we can assert on the actual request it sends, without hitting
/// the real server.
@MainActor
final class AuthenticationLogoutRevocationTests: XCTestCase {
    private let deviceToken = "device-token-1234567890123456789012"

    override func setUp() {
        super.setUp()
        // A stale value here would make configuredEndpoint() resolve to
        // something unexpected; force it back to the documented default.
        UserDefaults.standard.removeObject(forKey: "mcpCloudEndpoint")
        URLProtocol.registerClass(RevokeRequestRecordingProtocol.self)
        RevokeRequestRecordingProtocol.reset()
        MCPCloudCredentials.save(deviceToken)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(RevokeRequestRecordingProtocol.self)
        MCPCloudCredentials.clear()
        super.tearDown()
    }

    /// Account creation/login now happen server-side — these tests are about
    /// logout, not sign-in, so a signed-in device is seeded directly into
    /// Keychain instead of driving a real (network-dependent) login flow.
    private func makeLoggedInStore() -> AuthenticationStore {
        let service = "com.yabuko.studiquo.tests.\(UUID().uuidString)"
        KeychainCredentialFixtures.seedSignedInDevice(service: service, email: "student@example.com")
        return AuthenticationStore(service: service)
    }

    /// "ログアウト時にサーバー側の失効エンドポイントが正しく呼ばれること"
    func testLogoutCallsTheServerRevokeEndpointWithTheDeviceToken() async throws {
        let expectation = expectation(description: "revoke request sent")
        RevokeRequestRecordingProtocol.expectation = expectation

        makeLoggedInStore().logout()

        await fulfillment(of: [expectation], timeout: 2)
        let sent = RevokeRequestRecordingProtocol.capturedRequest
        XCTAssertEqual(sent?.url?.path, "/api/session/revoke")
        XCTAssertEqual(sent?.httpMethod, "POST")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "Authorization"), "Bearer \(deviceToken)")
    }

    /// "ログアウト後、以前発行されたトークンでAPIにアクセスしようとすると拒否されること" —
    /// from the client's perspective: once logout() has run, this device no
    /// longer holds a token it could even present to the API.
    func testLogoutClearsTheLocalTokenSoItCanNeverBePresentedAgain() async throws {
        let expectation = expectation(description: "revoke request sent")
        RevokeRequestRecordingProtocol.expectation = expectation

        makeLoggedInStore().logout()

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertNil(MCPCloudCredentials.currentToken())
    }

    /// The local token must be forgotten even if the server call never
    /// succeeds (offline logout) — sign-out can't be allowed to depend on
    /// connectivity, and a stale token left behind would defeat the fix.
    func testLocalTokenIsClearedEvenWhenTheRevokeRequestFails() async throws {
        let expectation = expectation(description: "revoke request sent")
        RevokeRequestRecordingProtocol.expectation = expectation
        RevokeRequestRecordingProtocol.shouldFail = true

        makeLoggedInStore().logout()

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertNil(MCPCloudCredentials.currentToken())
    }
}

/// Records the request made to `/api/session/revoke` and answers it without
/// touching the network. `canInit` matches by path only, so it's inert for
/// any other request `URLSession.shared` happens to make during the test.
private final class RevokeRequestRecordingProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _capturedRequest: URLRequest?
    static var expectation: XCTestExpectation?
    static var shouldFail = false

    static func reset() {
        lock.lock()
        _capturedRequest = nil
        expectation = nil
        shouldFail = false
        lock.unlock()
    }

    static var capturedRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return _capturedRequest
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/api/session/revoke"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._capturedRequest = request
        let exp = Self.expectation
        let fail = Self.shouldFail
        Self.lock.unlock()

        if fail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"revoked":true}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        exp?.fulfill()
    }

    override func stopLoading() {}
}
