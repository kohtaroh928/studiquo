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
    private var defaultsSuiteName = ""
    private var testDefaults: UserDefaults!
    private var testSession: URLSession!
    private var previousEndpoint: String?

    override func setUp() {
        super.setUp()
        previousEndpoint = UserDefaults.standard.string(forKey: "mcpCloudEndpoint")
        UserDefaults.standard.set(WorkerAIProvider.defaultEndpoint, forKey: "mcpCloudEndpoint")
        storeService = "com.yabuko.studiquo.tests.\(UUID().uuidString)"
        // A private suite, not `.standard` — the onboarding flag `login()`
        // etc. read/write is real, persistent app state, and `.standard` is
        // shared with any other copy of the app (or test) running on the
        // same simulator. Sharing it made these tests depend on nothing
        // else having touched that flag, which a manual run of the app
        // alongside the test suite silently violates.
        defaultsSuiteName = "com.yabuko.studiquo.tests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: defaultsSuiteName)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAuthNetworkProtocol.self]
        testSession = URLSession(configuration: configuration)
        StubAuthNetworkProtocol.reset()
    }

    override func tearDown() {
        testSession.invalidateAndCancel()
        testSession = nil
        MCPCloudCredentials.clear()
        testDefaults.removePersistentDomain(forName: defaultsSuiteName)
        if let previousEndpoint {
            UserDefaults.standard.set(previousEndpoint, forKey: "mcpCloudEndpoint")
        } else {
            UserDefaults.standard.removeObject(forKey: "mcpCloudEndpoint")
        }
        super.tearDown()
    }

    private func makeStore() -> AuthenticationStore {
        AuthenticationStore(service: storeService, defaults: testDefaults, authenticationSession: testSession)
    }

    func testBeingTurnedAwayFromSendingACodeShowsAWaitNotAFailure() async {
        StubAuthNetworkProtocol.respondInOrder(forPathSuffix: "api/auth/email/send-code", [
            (429, ["error": "Too many attempts. Please try again later."], [:]),
        ])
        let store = makeStore()

        let result = await store.beginAccountCreation(email: "new@example.com", password: "correct-horse-battery")

        XCTAssertFalse(result)
        XCTAssertEqual(store.errorMessage, "確認コードの送信が続いたため、いまは受け付けられません。しばらく待ってから、もう一度お試しください。")
        XCTAssertEqual(store.state, .needsLogin, "no code was sent, so there is nothing to verify yet")
        XCTAssertNil(store.pendingSignUpEmail.isEmpty ? nil : store.pendingSignUpEmail)
    }

    func testBeingTurnedAwayFromResendingKeepsTheSignUpInProgress() async {
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/email/send-code", status: 200, body: ["sent": true])
        let store = makeStore()
        _ = await store.beginAccountCreation(email: "new@example.com", password: "correct-horse-battery")
        XCTAssertEqual(store.state, .verifyingEmail)

        StubAuthNetworkProtocol.respondInOrder(forPathSuffix: "api/auth/email/send-code", [
            (429, ["error": "x"], ["Retry-After": "60"]),
        ])
        let resent = await store.requestEmailVerification()

        XCTAssertFalse(resent)
        XCTAssertEqual(store.errorMessage, "確認コードの送信が続いたため、いまは受け付けられません。あと約1分お待ちください。")
        XCTAssertEqual(store.state, .verifyingEmail, "the person stays on the code screen")
        XCTAssertEqual(store.pendingSignUpEmail, "new@example.com")
    }

    func testBeingTurnedAwayFromCheckingACodeIsNotAWrongCode() async {
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/email/send-code", status: 200, body: ["sent": true])
        let store = makeStore()
        _ = await store.beginAccountCreation(email: "new@example.com", password: "correct-horse-battery")

        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/email/confirm-code", status: 429, body: ["error": "Too many attempts. Please try again later."])
        let result = await store.confirmEmailVerification(code: "123456")

        XCTAssertFalse(result)
        XCTAssertEqual(store.errorMessage, "確認の試行が続いたため、いまは受け付けられません。しばらく待ってから、もう一度お試しください。")
        XCTAssertFalse(store.errorMessage.contains("正しくありません"))
        XCTAssertEqual(store.state, .verifyingEmail)
        XCTAssertNil(MCPCloudCredentials.currentToken())
    }

    // MARK: - breached password: change it on the code screen

    private func startSignUp(_ store: AuthenticationStore, password: String = "password-from-a-leak") async {
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/email/send-code", status: 200, body: ["sent": true])
        _ = await store.beginAccountCreation(email: "new@example.com", password: password)
        XCTAssertEqual(store.state, .verifyingEmail)
    }

    private let breachedResponse: (status: Int, body: [String: Any], headers: [String: String]) =
        (400, ["error": "breached", "code": "password_breached"], [:])

    func testABreachedPasswordKeepsTheCodeScreenAndAsksForAnotherPassword() async {
        let store = makeStore()
        await startSignUp(store)
        StubAuthNetworkProtocol.respondInOrder(forPathSuffix: "api/auth/email/confirm-code", [breachedResponse])

        let result = await store.confirmEmailVerification(code: "123456")

        XCTAssertFalse(result)
        XCTAssertTrue(store.needsNewPassword)
        XCTAssertEqual(store.state, .verifyingEmail, "no starting over")
        XCTAssertEqual(store.pendingSignUpEmail, "new@example.com")
        XCTAssertEqual(store.errorMessage, "このパスワードは過去の情報漏えいで見つかっています。別のパスワードを入力してください。")
        XCTAssertNil(MCPCloudCredentials.currentToken())
    }

    func testChangingThePasswordRetriesWithTheSameCodeAndTheNewPassword() async {
        let store = makeStore()
        await startSignUp(store)
        StubAuthNetworkProtocol.respondInOrder(forPathSuffix: "api/auth/email/confirm-code", [breachedResponse])
        _ = await store.confirmEmailVerification(code: "123456")

        StubAuthNetworkProtocol.respondInOrder(forPathSuffix: "api/auth/email/confirm-code", [
            (200, ["verified": true, "token": "1234567890.\(String(repeating: "a", count: 40))"], [:]),
        ])
        let result = await store.changePendingPassword("a-much-better-passphrase", code: "123456")

        XCTAssertTrue(result)
        XCTAssertFalse(store.needsNewPassword)
        XCTAssertEqual(store.state, .onboarding)
        let body = StubAuthNetworkProtocol.lastRequestBody(forPathSuffix: "api/auth/email/confirm-code")
        XCTAssertEqual(body?["code"] as? String, "123456", "the same code, not a new one")
        XCTAssertEqual(body?["password"] as? String, "a-much-better-passphrase")
        XCTAssertEqual(body?["email"] as? String, "new@example.com")
        XCTAssertEqual(StubAuthNetworkProtocol.requestCount(forPathSuffix: "api/auth/email/send-code"), 1, "no new code was sent")
    }

    func testAnotherBreachedPasswordAsksAgain() async {
        let store = makeStore()
        await startSignUp(store)
        StubAuthNetworkProtocol.respondInOrder(forPathSuffix: "api/auth/email/confirm-code", [breachedResponse, breachedResponse])
        _ = await store.confirmEmailVerification(code: "123456")

        let result = await store.changePendingPassword("password123", code: "123456")

        XCTAssertFalse(result)
        XCTAssertTrue(store.needsNewPassword)
        XCTAssertEqual(store.state, .verifyingEmail)
        XCTAssertTrue(store.errorMessage.contains("情報漏えい"))
    }

    func testAShortOrUnchangedPasswordIsRefusedWithoutAskingTheServer() async {
        let store = makeStore()
        await startSignUp(store)
        StubAuthNetworkProtocol.respondInOrder(forPathSuffix: "api/auth/email/confirm-code", [breachedResponse])
        _ = await store.confirmEmailVerification(code: "123456")
        let before = StubAuthNetworkProtocol.requestCount(forPathSuffix: "api/auth/email/confirm-code")

        let tooShort = await store.changePendingPassword("short", code: "123456")
        XCTAssertFalse(tooShort)
        XCTAssertEqual(store.errorMessage, "パスワードは8文字以上にしてください。")
        let unchanged = await store.changePendingPassword("password-from-a-leak", code: "123456")
        XCTAssertFalse(unchanged)
        XCTAssertEqual(store.errorMessage, "同じパスワードです。別のパスワードを入力してください。")

        XCTAssertTrue(store.needsNewPassword, "still waiting for a usable password")
        XCTAssertEqual(StubAuthNetworkProtocol.requestCount(forPathSuffix: "api/auth/email/confirm-code"), before)
    }

    func testAMistypedCodeAfterChangingThePasswordIsAnOrdinaryFailureWithThePasswordKept() async {
        let store = makeStore()
        await startSignUp(store)
        StubAuthNetworkProtocol.respondInOrder(forPathSuffix: "api/auth/email/confirm-code", [
            breachedResponse,
            (401, ["error": "Incorrect or expired code.", "attemptsRemaining": 3], [:]),
            (200, ["verified": true, "token": "1234567890.\(String(repeating: "a", count: 40))"], [:]),
        ])
        _ = await store.confirmEmailVerification(code: "123456")

        let failed = await store.changePendingPassword("a-much-better-passphrase", code: "000000")
        XCTAssertFalse(failed)
        XCTAssertFalse(store.needsNewPassword, "back to the plain confirm button")
        XCTAssertEqual(store.errorMessage, "コードが正しくありません。残り3回試せます。")

        // The plain confirm now goes out with the new password, not the refused one.
        let confirmed = await store.confirmEmailVerification(code: "123456")
        XCTAssertTrue(confirmed)
        XCTAssertEqual(StubAuthNetworkProtocol.lastRequestBody(forPathSuffix: "api/auth/email/confirm-code")?["password"] as? String, "a-much-better-passphrase")
    }

    func testCancellingOrRestartingClearsThePasswordPrompt() async {
        let store = makeStore()
        await startSignUp(store)
        StubAuthNetworkProtocol.respondInOrder(forPathSuffix: "api/auth/email/confirm-code", [breachedResponse])
        _ = await store.confirmEmailVerification(code: "123456")
        XCTAssertTrue(store.needsNewPassword)

        store.cancelAccountCreation()
        XCTAssertFalse(store.needsNewPassword)

        await startSignUp(store, password: "another-passphrase-1")
        StubAuthNetworkProtocol.respondInOrder(forPathSuffix: "api/auth/email/confirm-code", [breachedResponse])
        _ = await store.confirmEmailVerification(code: "123456")
        XCTAssertTrue(store.needsNewPassword)
        _ = await store.beginAccountCreation(email: "new@example.com", password: "yet-another-passphrase")
        XCTAssertFalse(store.needsNewPassword)
    }

    func testAChangePasswordCallWithNothingToChangeDoesNothing() async {
        let store = makeStore()
        let result = await store.changePendingPassword("a-much-better-passphrase", code: "123456")
        XCTAssertFalse(result)
        XCTAssertEqual(StubAuthNetworkProtocol.requestCount(forPathSuffix: "api/auth/email/confirm-code"), 0)
    }

    // MARK: - 429 / 503

    private func successBody() -> [String: Any] { ["token": "1234567890.\(String(repeating: "a", count: 40))"] }

    func testTooManyAttemptsExplainsTheWaitAndIsNotAWrongPassword() async {
        StubAuthNetworkProtocol.respondInOrder(forPathSuffix: "api/auth/local/login", [
            (429, ["error": "Too many attempts. Please try again later.", "retryAfterSeconds": 15], ["Retry-After": "15"]),
        ])
        let store = makeStore()

        let result = await store.login(email: "student@example.com", password: "correct-horse-battery")

        XCTAssertFalse(result)
        XCTAssertTrue(store.errorMessage.contains("あと約15秒お待ちください。"), store.errorMessage)
        XCTAssertFalse(store.errorMessage.contains("違います"))
        XCTAssertEqual(StubAuthNetworkProtocol.requestCount(forPathSuffix: "api/auth/local/login"), 1, "a wait is not retried on its own")
        XCTAssertNil(MCPCloudCredentials.currentToken())
        XCTAssertEqual(store.state, .needsLogin)
    }

    func testABusyServerIsRetriedOnItsOwnAndTheLoginSucceeds() async {
        StubAuthNetworkProtocol.respondInOrder(forPathSuffix: "api/auth/local/login", [
            (503, ["error": "The server is busy. Please try again in a moment."], ["Retry-After": "2"]),
            (503, ["error": "The server is busy. Please try again in a moment."], ["Retry-After": "2"]),
            (200, successBody(), [:]),
        ])
        let store = makeStore()
        var pauses: [TimeInterval] = []
        store.pauseBeforeRetry = { pauses.append($0) }

        let result = await store.login(email: "student@example.com", password: "correct-horse-battery")

        XCTAssertTrue(result)
        XCTAssertEqual(store.errorMessage, "")
        XCTAssertEqual(pauses, [2, 2], "paused for the time the server asked, twice")
        XCTAssertEqual(StubAuthNetworkProtocol.requestCount(forPathSuffix: "api/auth/local/login"), 3)
        XCTAssertEqual(store.state, .onboarding)
    }

    func testABusyServerThatStaysBusyEndsInAnHonestMessageAfterTwoRetries() async {
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/local/login", status: 503, body: ["error": "The server is busy. Please try again in a moment."])
        let store = makeStore()
        var pauses: [TimeInterval] = []
        store.pauseBeforeRetry = { pauses.append($0) }

        let result = await store.login(email: "student@example.com", password: "correct-horse-battery")

        XCTAssertFalse(result)
        XCTAssertEqual(store.errorMessage, "サーバーが混み合っています。少し待ってから、もう一度お試しください。")
        XCTAssertEqual(StubAuthNetworkProtocol.requestCount(forPathSuffix: "api/auth/local/login"), 1 + AuthenticationStore.busyRetryLimit)
        XCTAssertEqual(pauses.count, AuthenticationStore.busyRetryLimit)
        XCTAssertEqual(store.state, .needsLogin)
    }

    func testTheRetryPauseIsKeptWithinASaneRange() async {
        StubAuthNetworkProtocol.respondInOrder(forPathSuffix: "api/auth/local/login", [
            (503, ["error": "busy"], ["Retry-After": "600"]),
            (503, ["error": "busy"], ["Retry-After": "0.1"]),
            (200, successBody(), [:]),
        ])
        let store = makeStore()
        var pauses: [TimeInterval] = []
        store.pauseBeforeRetry = { pauses.append($0) }

        _ = await store.login(email: "student@example.com", password: "correct-horse-battery")

        XCTAssertEqual(pauses, [5, 1], "never longer than 5 s, never a busy loop")
    }

    func testAWrongPasswordIsStillAWrongPasswordAndIsNotRetried() async {
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/local/login", status: 401, body: ["error": "メールアドレスまたはパスワードが違います。"])
        let store = makeStore()
        var pauses = 0
        store.pauseBeforeRetry = { _ in pauses += 1 }

        _ = await store.login(email: "student@example.com", password: "wrong-password")

        XCTAssertEqual(store.errorMessage, "メールアドレスまたはパスワードが違います。")
        XCTAssertEqual(pauses, 0)
        XCTAssertEqual(StubAuthNetworkProtocol.requestCount(forPathSuffix: "api/auth/local/login"), 1)
    }


    // MARK: - login()

    func testLoginWithCorrectPasswordSucceedsAndSavesACloudToken() async {
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/local/login", status: 200, body: ["token": "1234567890.\(String(repeating: "a", count: 40))"])
        let store = makeStore()

        let result = await store.login(email: "student@example.com", password: "correct-horse-battery")

        XCTAssertTrue(result)
        XCTAssertEqual(store.errorMessage, "")
        XCTAssertEqual(store.state, .onboarding)
        XCTAssertEqual(MCPCloudCredentials.currentToken(), "1234567890.\(String(repeating: "a", count: 40))")
    }

    func testLoginWithWrongPasswordFailsWithoutSavingAnyToken() async {
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/local/login", status: 401, body: ["error": "メールアドレスまたはパスワードが違います。"])
        let store = makeStore()

        let result = await store.login(email: "student@example.com", password: "wrong-password")

        XCTAssertFalse(result)
        XCTAssertEqual(store.errorMessage, "メールアドレスまたはパスワードが違います。")
        XCTAssertEqual(store.state, .needsLogin)
        XCTAssertNil(MCPCloudCredentials.currentToken())
    }

    func testLoginWithEmptyFieldsFailsWithoutMakingANetworkCall() async {
        StubAuthNetworkProtocol.failIfCalled(forPathSuffix: "api/auth/local/login")
        let store = makeStore()

        let result = await store.login(email: "", password: "")

        XCTAssertFalse(result)
    }

    func testAnAlreadyAuthenticatedDeviceLoggingInAgainGoesStraightToAuthenticated() async {
        testDefaults.set(true, forKey: "authenticationOnboardingComplete")
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/local/login", status: 200, body: ["token": "1234567890.\(String(repeating: "b", count: 40))"])
        let store = makeStore()

        let result = await store.login(email: "student@example.com", password: "correct-horse-battery")

        XCTAssertTrue(result)
        XCTAssertEqual(store.state, .authenticated)
    }

    /// Regression coverage for a real failure this session: these tests used
    /// to read/write the onboarding flag straight through
    /// `UserDefaults.standard`, which every login-state assertion above
    /// depends on being unset. That is real, persistent, shared app state —
    /// a manually-run copy of the app on the same simulator (or simply
    /// having completed onboarding for real once) sets it permanently, and
    /// every one of the tests above then started reporting `.authenticated`
    /// where they expected `.onboarding`, with nothing wrong in the app
    /// itself. `AuthenticationStore` now takes an injected `defaults`, and
    /// this proves a poisoned `.standard` — exactly what a manual app run
    /// leaves behind — can no longer reach a store built with its own
    /// isolated suite.
    func testLoginIgnoresAStaleOnboardingFlagLeftInSharedUserDefaultsByAnotherAppInstance() async {
        UserDefaults.standard.set(true, forKey: "authenticationOnboardingComplete")
        defer { UserDefaults.standard.removeObject(forKey: "authenticationOnboardingComplete") }
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/local/login", status: 200, body: ["token": "1234567890.\(String(repeating: "f", count: 40))"])
        let store = makeStore()

        let result = await store.login(email: "student@example.com", password: "correct-horse-battery")

        XCTAssertTrue(result)
        XCTAssertEqual(store.state, .onboarding)
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
        let firstLaunch = makeStore()
        let signedIn = await firstLaunch.login(email: "student@example.com", password: "correct-horse-battery")
        XCTAssertTrue(signedIn)

        // A brand-new AuthenticationStore instance against the same Keychain
        // service simulates the app being force-quit and relaunched.
        let secondLaunch = makeStore()

        XCTAssertNotEqual(secondLaunch.state, .needsLogin)
        XCTAssertEqual(secondLaunch.email, "student@example.com")
    }

    func testRestoreWithNoPriorSignInStaysAtNeedsLogin() {
        let store = makeStore()

        XCTAssertEqual(store.state, .needsLogin)
    }

    // MARK: - confirmEmailVerification(): signup and password reset

    func testBeginAccountCreationThenConfirmWithTheRightCodeSignsIn() async {
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/email/send-code", status: 200, body: ["sent": true])
        StubAuthNetworkProtocol.jsonResponse(forPathSuffix: "api/auth/email/confirm-code", status: 200, body: ["verified": true, "token": "1234567890.\(String(repeating: "d", count: 40))"])
        let store = makeStore()

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
        let store = makeStore()
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
    // Answers handed out one per request, in order, before `stubs` is consulted.
    private static var sequences: [String: [(status: Int, body: [String: Any], headers: [String: String])]] = [:]
    private static var requestCounts: [String: Int] = [:]
    private static var lastBodies: [String: [String: Any]] = [:]

    final class Gate {
        fileprivate let semaphore: DispatchSemaphore
        fileprivate init(_ semaphore: DispatchSemaphore) { self.semaphore = semaphore }
        func signal() { semaphore.signal() }
    }

    static func reset() {
        lock.lock(); stubs = [:]; forbidden = []; sequences = [:]; requestCounts = [:]; lastBodies = [:]; lock.unlock()
    }

    static func respondInOrder(forPathSuffix suffix: String, _ responses: [(status: Int, body: [String: Any], headers: [String: String])]) {
        lock.lock(); sequences[suffix] = responses; lock.unlock()
    }

    /// The JSON body of the most recent request whose path ends with `suffix`.
    static func lastRequestBody(forPathSuffix suffix: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return lastBodies[suffix]
    }

    static func requestCount(forPathSuffix suffix: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requestCounts[suffix] ?? 0
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

    private static func jsonBody(of request: URLRequest) -> [String: Any]? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            data = collected
        }
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true // Dedicated test session must never reach the network.
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTAssertEqual(request.url?.host, "studiquo-mcp.studiquo-mcp-server.workers.dev", "Unexpected test request host")
        let path = request.url?.path ?? ""
        Self.lock.lock()
        let forbidden = Self.forbidden.first { path.hasSuffix($0) }
        var queued: (status: Int, body: [String: Any], headers: [String: String])?
        if let key = Self.sequences.keys.first(where: { path.hasSuffix($0) }), var list = Self.sequences[key], !list.isEmpty {
            queued = list.removeFirst()
            Self.sequences[key] = list
        }
        if let key = Self.sequences.keys.first(where: { path.hasSuffix($0) }) ?? Self.stubs.keys.first(where: { path.hasSuffix($0) }) {
            Self.requestCounts[key, default: 0] += 1
            if let body = Self.jsonBody(of: request) { Self.lastBodies[key] = body }
        }
        let match = Self.stubs.first { path.hasSuffix($0.key) }?.value
        Self.lock.unlock()

        if let queued {
            respond(status: queued.status, body: queued.body, headers: queued.headers)
            return
        }

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

    private func respond(status: Int, body: [String: Any], headers: [String: String] = [:]) {
        let data = try! JSONSerialization.data(withJSONObject: body)
        let fields = ["Content-Type": "application/json"].merging(headers) { _, new in new }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
