import XCTest
import UserNotifications
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

    // MARK: - .studiquoAuthFailed

    /// Regression coverage for "the login expired message shows up even
    /// though the login hadn't really expired": a definitive 401 from any
    /// authenticated server call now posts .studiquoAuthFailed, which this
    /// store observes and reacts to by signing out — so the user lands back
    /// on the login screen (state .needsLogin) instead of being stuck on a
    /// screen that will keep failing with the same rejected token.
    func testAuthFailedNotificationSignsOutAndReachesTheLoginScreen() async throws {
        let expectation = expectation(description: "revoke request sent")
        RevokeRequestRecordingProtocol.expectation = expectation
        let store = makeLoggedInStore()

        NotificationCenter.default.post(name: .studiquoAuthFailed, object: nil)

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(store.state, .needsLogin)
        XCTAssertFalse(store.errorMessage.isEmpty)
        XCTAssertNil(MCPCloudCredentials.currentToken())
    }

    /// A device that isn't signed in has nothing to sign out of — several
    /// independent polling loops could plausibly fire this around the same
    /// moment, and none of them should trigger a spurious revoke call.
    func testAuthFailedNotificationIsANoOpWhenAlreadySignedOut() async throws {
        let expectation = expectation(description: "revoke request must not be sent")
        expectation.isInverted = true
        RevokeRequestRecordingProtocol.expectation = expectation
        let store = AuthenticationStore(service: "com.yabuko.studiquo.tests.\(UUID().uuidString)")
        XCTAssertEqual(store.state, .needsLogin)

        NotificationCenter.default.post(name: .studiquoAuthFailed, object: nil)

        await fulfillment(of: [expectation], timeout: 0.5)
        XCTAssertEqual(store.state, .needsLogin)
    }
}

@MainActor
final class PushNotificationRegistrationTests: XCTestCase {
    private func dependencies(
        status: @escaping () async -> UNAuthorizationStatus,
        requestAuthorization: @escaping () async -> Bool = { false },
        registerForRemoteNotifications: @escaping @MainActor () -> Void = {},
        currentAuthorizationToken: @escaping () -> String? = { nil },
        storedDeviceToken: @escaping @MainActor () -> String? = { nil },
        saveDeviceToken: @escaping @MainActor (String) -> Void = { _ in },
        removeStoredDeviceToken: @escaping @MainActor () -> Void = {},
        registerDevice: @escaping (String, PushDeviceService.Environment, String) async throws -> Void = { _, _, _ in },
        unregisterDevice: @escaping (String, String) async throws -> Void = { _, _ in }
    ) -> PushNotificationRegistration.Dependencies {
        .init(
            authorizationStatus: status,
            requestAuthorization: requestAuthorization,
            registerForRemoteNotifications: registerForRemoteNotifications,
            currentAuthorizationToken: currentAuthorizationToken,
            storedDeviceToken: storedDeviceToken,
            saveDeviceToken: saveDeviceToken,
            removeStoredDeviceToken: removeStoredDeviceToken,
            registerDevice: registerDevice,
            unregisterDevice: unregisterDevice
        )
    }

    /// A silent launch/login refresh must never produce the permission
    /// prompt. Only the contextual entry point used by chat/reminders may do
    /// so, and a grant immediately starts APNs registration.
    func testPermissionPromptOnlyOccursFromContextualEntryPoint() async {
        var promptCount = 0
        var registrationCount = 0
        let sut = dependencies(
            status: { .notDetermined },
            requestAuthorization: { promptCount += 1; return true },
            registerForRemoteNotifications: { registrationCount += 1 }
        )

        await PushNotificationRegistration.refreshIfAuthorized(dependencies: sut)
        XCTAssertEqual(promptCount, 0)
        XCTAssertEqual(registrationCount, 0)

        await PushNotificationRegistration.requestAuthorizationInContext(dependencies: sut)
        XCTAssertEqual(promptCount, 1)
        XCTAssertEqual(registrationCount, 1)
    }

    /// With permission already granted, the launch/login refresh asks APNs
    /// for the current token again; the simulated callback then uploads that
    /// token to the account without showing another prompt.
    func testAuthorizedLaunchRefreshReregistersTheDevice() async {
        let uploaded = expectation(description: "device token uploaded")
        let tokenData = Data([0x01, 0xab, 0xff])
        var promptCount = 0
        var uploadedToken: String?
        var uploadedAuthorization: String?
        var sut: PushNotificationRegistration.Dependencies!
        sut = dependencies(
            status: { .authorized },
            requestAuthorization: { promptCount += 1; return true },
            registerForRemoteNotifications: {
                PushNotificationRegistration.didRegister(deviceToken: tokenData, dependencies: sut)
            },
            currentAuthorizationToken: { "account-token" },
            registerDevice: { token, _, authorization in
                uploadedToken = token
                uploadedAuthorization = authorization
                uploaded.fulfill()
            }
        )

        await PushNotificationRegistration.refreshIfAuthorized(dependencies: sut)
        await fulfillment(of: [uploaded], timeout: 1)

        XCTAssertEqual(promptCount, 0)
        XCTAssertEqual(uploadedToken, "01abff")
        XCTAssertEqual(uploadedAuthorization, "account-token")
    }

    func testDeniedNotificationsUnregisterTheStoredDevice() async {
        var storedToken: String? = "stored-device-token"
        var unregisteredToken: String?
        var unregisteredAuthorization: String?
        let sut = dependencies(
            status: { .denied },
            currentAuthorizationToken: { "account-token" },
            storedDeviceToken: { storedToken },
            removeStoredDeviceToken: { storedToken = nil },
            unregisterDevice: { token, authorization in
                unregisteredToken = token
                unregisteredAuthorization = authorization
            }
        )

        await PushNotificationRegistration.refreshIfAuthorized(dependencies: sut)

        XCTAssertEqual(unregisteredToken, "stored-device-token")
        XCTAssertEqual(unregisteredAuthorization, "account-token")
        XCTAssertNil(storedToken)
    }

    func testLogoutUnregistersTheDeviceBeforeRevokingCredentials() async {
        let finished = expectation(description: "logout actions complete")
        var order: [String] = []
        let store = AuthenticationStore(
            service: "com.yabuko.studiquo.tests.\(UUID().uuidString)",
            unregisterPushDevice: { order.append("unregister-device") },
            revokeCloudCredentials: {
                order.append("revoke-credentials")
                finished.fulfill()
            }
        )

        store.logout()
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(order, ["unregister-device", "revoke-credentials"])
    }

    func testAPNsBinaryTokenConvertsToLowercaseHex() {
        let data = Data([0x00, 0x01, 0x0f, 0x10, 0xab, 0xff])

        XCTAssertEqual(PushNotificationRegistration.hexToken(from: data), "00010f10abff")
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
