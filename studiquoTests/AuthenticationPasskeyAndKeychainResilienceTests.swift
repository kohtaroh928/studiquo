import Foundation
import Security
import XCTest
@testable import studiquo

@MainActor
final class AuthenticationPasskeyAndKeychainResilienceTests: XCTestCase {
    private var storeService = ""
    private var defaultsSuiteName = ""
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        storeService = "com.yabuko.studiquo.auth-resilience.\(UUID().uuidString)"
        defaultsSuiteName = "com.yabuko.studiquo.auth-resilience.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: defaultsSuiteName)
        MCPCloudCredentials.clear()
    }

    override func tearDown() {
        MCPCloudCredentials.clear()
        testDefaults.removePersistentDomain(forName: defaultsSuiteName)
        for account in ["session", "passkey-identity", "oauth-identity"] {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: storeService,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
        }
        super.tearDown()
    }

    private func makeSignedInStore(token: String) -> AuthenticationStore {
        KeychainCredentialFixtures.seedSignedInDevice(service: storeService, email: "student@example.com")
        MCPCloudCredentials.save(token)
        return AuthenticationStore(
            service: storeService,
            defaults: testDefaults,
            unregisterPushDevice: {},
            revokeCloudCredentials: {}
        )
    }

    // MARK: - 1. .studiquoAuthFailed message distinction & ignoresAuthFailures guard

    func testAuthFailureDistinguishesUnexpiredRejectedTokenFromExpiredToken() async {
        let freshToken = "\(Int(Date().timeIntervalSince1970))." + String(repeating: "a", count: 48)
        let store = makeSignedInStore(token: freshToken)
        XCTAssertEqual(store.state, .onboarding)

        NotificationCenter.default.post(name: .studiquoAuthFailed, object: nil)
        // Allow main queue Combine sink to deliver
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(store.state, .needsLogin)
        XCTAssertEqual(
            store.errorMessage,
            "サインイン情報が確認できませんでした。もう一度サインインしてください。"
        )
    }

    func testIgnoresAuthFailuresKeepsSessionAliveOn401Broadcast() async {
        let freshToken = "\(Int(Date().timeIntervalSince1970))." + String(repeating: "b", count: 48)
        let store = makeSignedInStore(token: freshToken)
        store.ignoresAuthFailures = true

        NotificationCenter.default.post(name: .studiquoAuthFailed, object: nil)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(store.state, .onboarding, "ignoresAuthFailures must prevent automatic sign-out")
        XCTAssertEqual(store.errorMessage, "")
    }

    // MARK: - 2. Email & password input validation before network

    func testBeginAccountCreationValidatesEmailAndPasswordBoundsBeforeTouchingNetwork() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailOnAnyRequestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let store = AuthenticationStore(
            service: storeService,
            defaults: testDefaults,
            unregisterPushDevice: {},
            revokeCloudCredentials: {},
            authenticationSession: session
        )

        let noAtSign = await store.beginAccountCreation(email: "invalid-email.com", password: "validPassword123")
        XCTAssertFalse(noAtSign)
        XCTAssertEqual(store.errorMessage, "正しいメールアドレスを入力してください。")

        let tooLongEmail = String(repeating: "a", count: 250) + "@b.com"
        let overLimitEmail = await store.beginAccountCreation(email: tooLongEmail, password: "validPassword123")
        XCTAssertFalse(overLimitEmail)
        XCTAssertEqual(store.errorMessage, "正しいメールアドレスを入力してください。")

        let shortPassword = await store.beginAccountCreation(email: "user@example.com", password: "1234567")
        XCTAssertFalse(shortPassword)
        XCTAssertEqual(store.errorMessage, "パスワードは8文字以上にしてください。")

        let hugePassword = String(repeating: "p", count: 1_025)
        let overLimitPassword = await store.beginAccountCreation(email: "user@example.com", password: hugePassword)
        XCTAssertFalse(overLimitPassword)
        XCTAssertEqual(store.errorMessage, "パスワードは8文字以上にしてください。")
        XCTAssertEqual(store.state, .needsLogin)
    }

    // MARK: - 3. First passkey email-code guard & onboarding completion

    func testPasskeyEmailCodeGuardsRejectEmptyEmailOrBlankCodeWithoutNetworkCall() async {
        let store = AuthenticationStore(
            service: storeService,
            defaults: testDefaults,
            unregisterPushDevice: {},
            revokeCloudCredentials: {}
        )
        // Signed-out store has empty `email`
        XCTAssertEqual(store.email, "")
        await store.sendPasskeyEmailCode()
        XCTAssertFalse(store.passkeyEmailCodeSent)
        XCTAssertFalse(store.isPasskeyBusy)

        let confirmedEmptyEmail = await store.confirmPasskeyEmailCode("123456")
        XCTAssertFalse(confirmedEmptyEmail)

        // Signed-in store with non-empty email still rejects whitespace-only code
        let signedIn = makeSignedInStore(token: "\(Int(Date().timeIntervalSince1970))." + String(repeating: "c", count: 48))
        let confirmedBlankCode = await signedIn.confirmPasskeyEmailCode("   \n\t ")
        XCTAssertFalse(confirmedBlankCode)
        XCTAssertFalse(signedIn.isPasskeyBusy)
    }

    func testFinishOnboardingPersistsFlagAndTransitionsToAuthenticated() async {
        let freshToken = "\(Int(Date().timeIntervalSince1970))." + String(repeating: "d", count: 48)
        let store = makeSignedInStore(token: freshToken)
        XCTAssertEqual(store.state, .onboarding)

        store.finishOnboarding()
        XCTAssertEqual(store.state, .authenticated)
        XCTAssertTrue(testDefaults.bool(forKey: "authenticationOnboardingComplete"))

        await store.waitForRevenueCatIdentity(timeout: .milliseconds(20))
    }
}

private final class FailOnAnyRequestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Network request must not be made when local validation fails: \(String(describing: request.url))")
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}
