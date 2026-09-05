import XCTest
@testable import studiquo

/// Password verification and "forgot password" both now happen server-side
/// (see local-auth.js / mcp-server), so these tests exercise
/// AuthenticationStore.login()/confirmEmailVerification() against a stubbed
/// network instead of a local Keychain-only check — the same URLProtocol
/// approach AuthenticationLogoutRevocationTests.swift uses for logout.
@MainActor
final class AuthenticationStoreTests: XCTestCase {
    private var storeService = ""

    override func setUp() {
        super.setUp()
        storeService = "com.yabuko.studiquo.tests.\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: "mcpCloudEndpoint")
        URLProtocol.registerClass(StubAuthNetworkProtocol.self)
        StubAuthNetworkProtocol.reset()
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubAuthNetworkProtocol.self)
        MCPCloudCredentials.clear()
        super.tearDown()
    }

    // MARK: - login()

    func testLoginWithCorrectPasswordSucceedsAndSavesACloudToken() async {
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/local/login", status: 200, body: ["token": "1234567890.\(String(repeating: "a", count: 40))"])
        let store = AuthenticationStore(service: storeService)

        let result = await store.login(email: "student@example.com", password: "correct-horse-battery")

        XCTAssertTrue(result)
        XCTAssertEqual(store.errorMessage, "")
        XCTAssertEqual(store.state, .onboarding)
        XCTAssertEqual(MCPCloudCredentials.currentToken(), "1234567890.\(String(repeating: "a", count: 40))")
    }

    func testLoginWithWrongPasswordFailsWithoutSavingAnyToken() async {
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/local/login", status: 401, body: ["error": "メールアドレスまたはパスワードが違います。"])
        let store = AuthenticationStore(service: storeService)

        let result = await store.login(email: "student@example.com", password: "wrong-password")

        XCTAssertFalse(result)
        XCTAssertEqual(store.errorMessage, "メールアドレスまたはパスワードが違います。")
        XCTAssertEqual(store.state, .needsLogin)
        XCTAssertNil(MCPCloudCredentials.currentToken())
    }

    func testLoginWithEmptyFieldsFailsWithoutMakingANetworkCall() async {
        StubAuthNetworkProtocol.failIfCalled(forPathSuffix: "api/auth/local/login")
        let store = AuthenticationStore(service: storeService)

        let result = await store.login(email: "", password: "")

        XCTAssertFalse(result)
    }

    func testAnAlreadyAuthenticatedDeviceLoggingInAgainGoesStraightToAuthenticated() async {
        UserDefaults.standard.set(true, forKey: "authenticationOnboardingComplete")
        defer { UserDefaults.standard.removeObject(forKey: "authenticationOnboardingComplete") }
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/local/login", status: 200, body: ["token": "1234567890.\(String(repeating: "b", count: 40))"])
        let store = AuthenticationStore(service: storeService)

        let result = await store.login(email: "student@example.com", password: "correct-horse-battery")

        XCTAssertTrue(result)
        XCTAssertEqual(store.state, .authenticated)
    }

    // MARK: - restore(): the device must recognize a real sign-in after a cold launch

    /// Regression coverage for a real bug found this session: Apple/Google
    /// sign-in saved a valid 6-month session but no local identity marker, so
    /// restore() bounced signed-in users back to the login screen on every
    /// cold launch. login()/confirmEmailVerification() now persist an
    /// "oauth-identity" record (provider "email") the same way
    /// loginWithApple/loginWithGoogle do — this verifies restore() actually
    /// honors it on a *freshly constructed* store, simulating relaunch.
    func testRestoreRecognizesALocalEmailIdentityAfterRelaunch() async {
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/local/login", status: 200, body: ["token": "1234567890.\(String(repeating: "c", count: 40))"])
        let firstLaunch = AuthenticationStore(service: storeService)
        let signedIn = await firstLaunch.login(email: "student@example.com", password: "correct-horse-battery")
        XCTAssertTrue(signedIn)

        // A brand-new AuthenticationStore instance against the same Keychain
        // service simulates the app being force-quit and relaunched.
        let secondLaunch = AuthenticationStore(service: storeService)

        XCTAssertNotEqual(secondLaunch.state, .needsLogin)
        XCTAssertEqual(secondLaunch.email, "student@example.com")
    }

    func testRestoreWithNoPriorSignInStaysAtNeedsLogin() {
        let store = AuthenticationStore(service: storeService)

        XCTAssertEqual(store.state, .needsLogin)
    }

    // MARK: - confirmEmailVerification(): signup and password reset

    func testBeginAccountCreationThenConfirmWithTheRightCodeSignsIn() async {
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/email/send-code", status: 200, body: ["sent": true])
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/email/confirm-code", status: 200, body: ["verified": true, "token": "1234567890.\(String(repeating: "d", count: 40))"])
        let store = AuthenticationStore(service: storeService)

        let began = await store.beginAccountCreation(email: "student@example.com", password: "correct-horse-battery")
        XCTAssertTrue(began)
        XCTAssertEqual(store.state, .verifyingEmail)
        XCTAssertEqual(store.pendingSignUpEmail, "student@example.com")

        let confirmed = await store.confirmEmailVerification(code: "123456")
        XCTAssertTrue(confirmed)
        XCTAssertEqual(store.state, .onboarding)
        XCTAssertEqual(MCPCloudCredentials.currentToken(), "1234567890.\(String(repeating: "d", count: 40))")
    }

    /// Regression coverage for a real bug found this session: cancelling
    /// during an in-flight confirm-code request used to not stop the account
    /// from being persisted once the (slow) network response arrived.
    /// cancelAccountCreation() clears pendingSignUp, and
    /// confirmEmailVerification() must notice that and refuse to sign in.
    func testCancelingWhileConfirmationIsInFlightPreventsSignIn() async {
        let gate = StubAuthNetworkProtocol.jsonResponse(
            forPathSuffix: "api/auth/email/confirm-code", status: 200,
            body: ["verified": true, "token": "1234567890.\(String(repeating: "e", count: 40))"],
            holdUntilSignaled: true
        )
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/email/send-code", status: 200, body: ["sent": true])
        let store = AuthenticationStore(service: storeService)
        _ = await store.beginAccountCreation(email: "student@example.com", password: "correct-horse-battery")

        async let confirmTask = store.confirmEmailVerification(code: "123456")
        store.cancelAccountCreation()
        gate.signal()
        let confirmed = await confirmTask

        XCTAssertFalse(confirmed)
        XCTAssertEqual(store.state, .needsLogin)
        XCTAssertNil(MCPCloudCredentials.currentToken())
    }
}

/// Stubs every request this test file's network calls make, keyed by the
/// last path component(s) of the URL. `holdUntilSignaled` lets a test
/// control exactly when a slow response "arrives", to reproduce a race.
private final class StubAuthNetworkProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var stubs: [String: (status: Int, body: [String: Any], gate: DispatchSemaphore?)] = [:]
    private static var forbidden: Set<String> = []

    final class Gate {
        fileprivate let semaphore: DispatchSemaphore
        fileprivate init(_ semaphore: DispatchSemaphore) { self.semaphore = semaphore }
        func signal() { semaphore.signal() }
    }

    static func reset() {
        lock.lock(); stubs = [:]; forbidden = []; lock.unlock()
    }

    @discardableResult
    static func jsonResponse(forPathSuffix suffix: String, status: Int, body: [String: Any], holdUntilSignaled: Bool = false) -> Gate {
        let semaphore = holdUntilSignaled ? DispatchSemaphore(value: 0) : nil
        lock.lock(); stubs[suffix] = (status, body, semaphore); lock.unlock()
        return Gate(semaphore ?? DispatchSemaphore(value: 1))
    }

    static func failIfCalled(forPathSuffix suffix: String) {
        lock.lock(); forbidden.insert(suffix); lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "studiquo-mcp.studiquo-mcp-server.workers.dev"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock()
        let forbidden = Self.forbidden.first { path.hasSuffix($0) }
        let match = Self.stubs.first { path.hasSuffix($0.key) }?.value
        Self.lock.unlock()

        if forbidden != nil {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        guard let match else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        if let gate = match.gate {
            DispatchQueue.global().async {
                gate.wait()
                self.respond(status: match.status, body: match.body)
            }
        } else {
            respond(status: match.status, body: match.body)
        }
    }

    private func respond(status: Int, body: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
