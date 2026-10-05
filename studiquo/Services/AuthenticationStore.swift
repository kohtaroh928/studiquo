import Combine
import Foundation
import RevenueCat
import Security
import AuthenticationServices
import SwiftData

extension Notification.Name {
    /// Posted by FriendChatService/AIProvider/DocumentCollabService whenever
    /// the server rejects this device's cloud token with 401 — a
    /// trustworthy signal now that MCPCloudCredentials.loadOrCreateToken()
    /// no longer silently swaps in a token the server has never seen (see
    /// its own doc comment in ContentView.swift). AuthenticationStore
    /// observes this to sign the device out and return it to the login
    /// screen, instead of leaving the user stuck on a screen that will keep
    /// failing with the same token forever.
    static let studiquoAuthFailed = Notification.Name("StudiquoAuthFailed")
}

@MainActor
final class AuthenticationStore: ObservableObject {
    enum State: Equatable {
        case needsLogin
        case verifyingEmail
        case onboarding
        case authenticated
    }

    @Published private(set) var state: State = .needsLogin
    @Published var errorMessage = ""
    /// UI tests sign in without a real token, so every server call 401s;
    /// they set this so only an explicit logout ends the session.
    var ignoresAuthFailures = false
    @Published private(set) var isPasskeyBusy = false
    @Published private(set) var isAppleSignInBusy = false
    @Published private(set) var isGoogleSignInBusy = false
    @Published private(set) var isEmailVerifyBusy = false
    @Published private(set) var isLoginBusy = false
    @Published private(set) var isAccountDeletionBusy = false

    private let sessionAccount = "session"
    private let service: String
    private let onboardingKey = "authenticationOnboardingComplete"
    private let passkeyIdentityAccount = "passkey-identity"
    private let oauthIdentityAccount = "oauth-identity"
    private let now: () -> Date
    private let defaults: UserDefaults
    private let unregisterPushDevice: () async -> Void
    private let revokeCloudCredentials: () async -> Void
    private let deleteAccountOnServer: () async throws -> Void
    /// Email + new password held only in memory between `beginAccountCreation`
    /// and a successful `confirmEmailVerification` — nothing is written to
    /// Keychain until the code is confirmed, so an abandoned sign-up (or
    /// password reset) leaves no trace on disk. The server, not this device,
    /// owns the account: this is only ever a request to set the password for
    /// a now-verified email, which covers both initial signup and "forgot
    /// password" identically (see EmailVerificationService.confirmCode).
    private var pendingSignUp: (email: String, password: String)?
    /// Cancelled automatically on deinit — see .studiquoAuthFailed and
    /// handleAuthFailure() below.
    private var authFailureSubscription: AnyCancellable?

    /// `service`/`now`/`defaults` are overridable so tests can use an
    /// isolated Keychain service, a fake clock, and an isolated UserDefaults
    /// suite — without this, the `onboardingKey` flag below reads/writes the
    /// real, shared `UserDefaults.standard`, which a manually-run copy of
    /// the app on the same simulator (or another test) can leave set to
    /// `true`, making a freshly-constructed store in a test jump straight
    /// to `.authenticated` when it expects `.onboarding`.
    init(
        service: String = "com.yabuko.studiquo.authentication",
        now: @escaping () -> Date = Date.init,
        defaults: UserDefaults = .standard,
        unregisterPushDevice: @escaping () async -> Void = { await PushNotificationRegistration.unregisterCurrentDevice() },
        revokeCloudCredentials: @escaping () async -> Void = { await MCPCloudCredentials.revoke() },
        deleteAccountOnServer: @escaping () async throws -> Void = { try await AccountDeletionService.deleteAccount() }
    ) {
        self.service = service
        self.now = now
        self.defaults = defaults
        self.unregisterPushDevice = unregisterPushDevice
        self.revokeCloudCredentials = revokeCloudCredentials
        self.deleteAccountOnServer = deleteAccountOnServer
        restore()
        authFailureSubscription = NotificationCenter.default.publisher(for: .studiquoAuthFailed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleAuthFailure() }
    }

    var email: String {
        oauthIdentity()?.email ?? passkeyIdentity()?.email ?? ""
    }

    /// The email a verification code was just sent to — set while `state ==
    /// .verifyingEmail`, since that identity isn't recognized locally yet
    /// for `email` (above) to find.
    var pendingSignUpEmail: String {
        pendingSignUp?.email ?? ""
    }

    /// Starts account creation (or a password reset — same request either
    /// way) without touching Keychain: validates the email/password and
    /// sends a verification code, holding both in memory as `pendingSignUp`.
    /// Nothing is persisted until `confirmEmailVerification(code:)` proves
    /// the address is real.
    func beginAccountCreation(email: String, password: String) async -> Bool {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count <= 254, normalized.contains("@"), normalized.contains(".") else {
            errorMessage = "正しいメールアドレスを入力してください。"
            return false
        }
        guard password.count >= 8, password.count <= 1_024 else {
            errorMessage = "パスワードは8文字以上にしてください。"
            return false
        }
        isEmailVerifyBusy = true
        defer { isEmailVerifyBusy = false }
        do {
            try await EmailVerificationService.sendCode(email: normalized)
            pendingSignUp = (normalized, password)
            errorMessage = ""
            state = .verifyingEmail
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Verifies email/password against the server (see local-auth.js —
    /// password never leaves this call except over HTTPS, and is never
    /// stored locally). A real, server-issued token is what makes `restore()`
    /// recognize this device on the next cold launch, same as every other
    /// sign-in method.
    func login(email: String, password: String) async -> Bool {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, !password.isEmpty else {
            errorMessage = "メールアドレスとパスワードを入力してください。"
            return false
        }
        isLoginBusy = true
        defer { isLoginBusy = false }
        do {
            let token = try await LocalAuthService.login(email: normalized, password: password)
            MCPCloudCredentials.save(token)
            persistOAuthIdentity(provider: "email", subject: normalized, email: normalized)
            createSession()
            syncRevenueCatIdentity(provider: "email", subject: normalized)
            errorMessage = ""
            state = defaults.bool(forKey: onboardingKey) ? .authenticated : .onboarding
            return true
        } catch {
            errorMessage = "メールアドレスまたはパスワードが違います。"
            return false
        }
    }

    func finishOnboarding() {
        defaults.set(true, forKey: onboardingKey)
        state = .authenticated
    }

    func logout() {
        delete(account: sessionAccount)
        state = .needsLogin
        // Best-effort and non-blocking: remove this device while the bearer
        // token is still available, then revoke that token. Local sign-out
        // itself never waits on either network call.
        Task {
            await unregisterPushDevice()
            await revokeCloudCredentials()
        }
        // Detaches this device from whichever account it was just logged in
        // as — the next sign-in calls `logIn(_:)` again (possibly as a
        // different person on a shared device), and RevenueCat must not
        // keep attributing their purchases to whoever signed out.
        Task { _ = try? await Purchases.shared.logOut() }
    }

    func requestAccountDeletion() async -> Bool {
        guard !isAccountDeletionBusy else { return false }
        isAccountDeletionBusy = true
        defer { isAccountDeletionBusy = false }
        do {
            try await deleteAccountOnServer()
            errorMessage = ""
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func finishAccountDeletion() {
        MCPCloudCredentials.clear()
        delete(account: sessionAccount)
        delete(account: passkeyIdentityAccount)
        delete(account: oauthIdentityAccount)
        pendingSignUp = nil
        defaults.removeObject(forKey: onboardingKey)
        errorMessage = ""
        state = .needsLogin
        // The account itself is gone server-side; detach RevenueCat from it
        // too so a subsequent sign-in (even as the same deleted identity,
        // should the provider allow it) starts from a clean entitlement
        // slate rather than inheriting the deleted account's purchases.
        Task { _ = try? await Purchases.shared.logOut() }
    }

    /// A definitive 401 from any authenticated server call (see
    /// .studiquoAuthFailed) means this device's token is genuinely no good,
    /// not a transient network blip — signs the device out so the user lands
    /// back on the login screen instead of being stuck on a screen that will
    /// keep failing with the same token. A no-op once already signed out, so
    /// several independent polling loops firing this around the same moment
    /// is harmless.
    private func handleAuthFailure() {
        guard !ignoresAuthFailures else { return }
        guard state == .authenticated || state == .onboarding else { return }
        let reallyExpired = MCPCloudCredentials.currentToken().map(MCPCloudCredentials.isExpired) ?? true
        errorMessage = reallyExpired
            ? "ログインの有効期限が切れました。もう一度サインインしてください。"
            : "サインイン情報が確認できませんでした。もう一度サインインしてください。"
        logout()
    }

    /// Re-sends the verification code for the sign-up (or reset) in progress
    /// — used by the confirmation screen's "コードを再送信".
    func requestEmailVerification() async -> Bool {
        guard let pending = pendingSignUp else { return false }
        isEmailVerifyBusy = true
        defer { isEmailVerifyBusy = false }
        do {
            try await EmailVerificationService.sendCode(email: pending.email)
            errorMessage = ""
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// The account's password is only ever actually set here, once the code
    /// proves `pendingSignUp`'s email is real — see beginAccountCreation().
    /// Covers both initial signup and password reset identically.
    func confirmEmailVerification(code: String) async -> Bool {
        guard let pending = pendingSignUp else { return false }
        isEmailVerifyBusy = true
        defer { isEmailVerifyBusy = false }
        do {
            let token = try await EmailVerificationService.confirmCode(
                email: pending.email, code: code, password: pending.password,
                randomValue: MCPCloudCredentials.makeRandomValue()
            )
            // The user may have tapped キャンセル (or started a different
            // sign-up) while the request above was in flight — don't
            // resurrect an abandoned sign-up/reset.
            guard pendingSignUp?.email == pending.email else { return false }
            MCPCloudCredentials.save(token)
            persistOAuthIdentity(provider: "email", subject: pending.email, email: pending.email)
            pendingSignUp = nil
            createSession()
            syncRevenueCatIdentity(provider: "email", subject: pending.email)
            errorMessage = ""
            state = defaults.bool(forKey: onboardingKey) ? .authenticated : .onboarding
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Abandons the sign-up/reset in progress and returns to the login screen
    /// — the code already sent is simply left to expire on its own. Setting
    /// `pendingSignUp = nil` here (rather than only flipping `state`) is what
    /// lets a `confirmEmailVerification(code:)` already in flight notice the
    /// cancellation and refuse to act on it.
    func cancelAccountCreation() {
        guard state == .verifyingEmail else { return }
        pendingSignUp = nil
        errorMessage = ""
        state = .needsLogin
    }

    func addPasskey() async -> Bool {
        guard !email.isEmpty else { return false }
        isPasskeyBusy = true
        defer { isPasskeyBusy = false }
        do {
            try await PasskeyService.shared.register(
                email: email,
                token: MCPCloudCredentials.loadOrCreateToken()
            )
            errorMessage = ""
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func loginWithPasskey() async -> Bool {
        isPasskeyBusy = true
        defer { isPasskeyBusy = false }
        do {
            let identity = try await PasskeyService.shared.login()
            MCPCloudCredentials.save(identity.token)
            guard save(PasskeyIdentity(email: identity.email), account: passkeyIdentityAccount) else {
                throw PasskeyError.invalidResponse
            }
            createSession()
            syncRevenueCatIdentity(provider: "email", subject: identity.email)
            errorMessage = ""
            state = defaults.bool(forKey: onboardingKey) ? .authenticated : .onboarding
            return true
        } catch let error as ASAuthorizationError where error.code == .canceled {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// `result` is SwiftUI's `SignInWithAppleButton` completion: its own
    /// ASAuthorizationController already ran by the time this is called, so
    /// this only finishes the exchange — it never starts a second prompt.
    func loginWithApple(result: Result<ASAuthorization, Error>) async -> Bool {
        switch result {
        case .failure(let error as ASAuthorizationError) where error.code == .canceled:
            return false
        case .failure(let error):
            errorMessage = error.localizedDescription
            return false
        case .success(let authorization):
            isAppleSignInBusy = true
            defer { isAppleSignInBusy = false }
            do {
                let identity = try await AppleSignInService.shared.completeSignIn(with: authorization)
                // Without this, restore() has no local record of an
                // Apple-signed-in user and bounces them back to the login
                // screen on every cold launch despite a valid session.
                // Apple only sends `email` on the very first authorization,
                // so a later sign-in with `email == nil` must not clobber
                // what an earlier one already learned.
                persistOAuthIdentity(provider: "apple", subject: identity.subject, email: identity.email)
                createSession()
                syncRevenueCatIdentity(provider: "apple", subject: identity.subject)
                errorMessage = ""
                state = defaults.bool(forKey: onboardingKey) ? .authenticated : .onboarding
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
    }

    /// Unlike `loginWithApple(result:)`, GoogleSignInSwift's button has no
    /// built-in flow of its own to hand back a result from — this starts and
    /// finishes the whole native Google sign-in flow itself, same as
    /// AppleSignInService.signIn().
    func loginWithGoogle() async -> Bool {
        isGoogleSignInBusy = true
        defer { isGoogleSignInBusy = false }
        do {
            let identity = try await GoogleSignInService.shared.signIn()
            // Without this, restore() has no local record of a
            // Google-signed-in user and bounces them back to the login
            // screen on every cold launch despite a valid session.
            persistOAuthIdentity(provider: "google", subject: identity.subject, email: identity.email)
            createSession()
            syncRevenueCatIdentity(provider: "google", subject: identity.subject)
            errorMessage = ""
            state = defaults.bool(forKey: onboardingKey) ? .authenticated : .onboarding
            return true
        } catch let error as NSError where error.domain == "com.google.GIDSignIn" && error.code == -5 {
            // GIDSignInError.canceled: the user dismissed the sign-in sheet.
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func restore() {
        guard (passkeyIdentity() != nil || oauthIdentity() != nil),
              let session: SessionRecord = load(account: sessionAccount), session.expiresAt > Date() else {
            state = .needsLogin
            return
        }
        // Active use renews the six-month session.
        createSession()
        state = defaults.bool(forKey: onboardingKey) ? .authenticated : .onboarding
    }

    private func createSession() {
        guard let expiresAt = Calendar.current.date(byAdding: .month, value: 6, to: Date()) else { return }
        _ = save(SessionRecord(token: UUID().uuidString, expiresAt: expiresAt), account: sessionAccount)
    }

    /// Logs this device into RevenueCat as the same canonical identity the
    /// server computes as `session.sub` for `mintSession`'s `identityKey`
    /// (see app.js's handleAppleSignIn/handleGoogleSignIn/local email+passkey
    /// paths) — without this, the RevenueCat webhook's `app_user_id` and this
    /// account's `sub` never match, and `getPlan` in entitlements.js can
    /// never see this account actually has an active purchase.
    ///
    /// Fire-and-forget: a failed RevenueCat login must never block sign-in
    /// itself, and there's no useful recovery to show the student for it —
    /// the next successful RevenueCat call (e.g. opening プラン) re-sends
    /// whichever `app_user_id` is currently logged in.
    private func syncRevenueCatIdentity(provider: String, subject: String) {
        let canonicalIdentity: String
        switch provider {
        case "google": canonicalIdentity = "google:\(subject)"
        case "email": canonicalIdentity = "email:\(subject)"
        default: canonicalIdentity = subject // Apple: the bare JWT `sub`, unprefixed.
        }
        Task { _ = try? await Purchases.shared.logIn(canonicalIdentity) }
    }

    private func passkeyIdentity() -> PasskeyIdentity? { load(account: passkeyIdentityAccount) }
    private func oauthIdentity() -> OAuthIdentity? { load(account: oauthIdentityAccount) }

    /// Records that this device has an Apple/Google/email identity so
    /// `restore()` recognizes it on the next cold launch. `email` is nil on
    /// every Apple sign-in after the first, so a later sign-in must not
    /// overwrite an email an earlier one already learned.
    private func persistOAuthIdentity(provider: String, subject: String, email: String?) {
        let resolvedEmail = email ?? oauthIdentity()?.email
        _ = save(OAuthIdentity(provider: provider, subject: subject, email: resolvedEmail), account: oauthIdentityAccount)
    }

    private func save<T: Encodable>(_ value: T, account: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private func load<T: Decodable>(account: String) -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func delete(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}

private struct SessionRecord: Codable {
    let token: String
    let expiresAt: Date
}

private struct PasskeyIdentity: Codable {
    let email: String
}

private struct OAuthIdentity: Codable {
    let provider: String
    let subject: String
    let email: String?
}

enum AccountDeletionService {
    static func deleteAccount() async throws {
        guard let token = MCPCloudCredentials.currentToken(),
              let endpoint = MCPCloudCredentials.configuredEndpoint() else {
            throw AccountDeletionError.notSignedIn
        }
        var request = URLRequest(url: endpoint.appending(path: "api/account"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["confirmation": "DELETE"])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw AccountDeletionError.rejected
        }
    }
}

enum AccountDeletionError: LocalizedError {
    case notSignedIn, rejected

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "ログイン情報を確認できませんでした。もう一度ログインしてください。"
        case .rejected: "アカウントを削除できませんでした。通信状態を確認して、もう一度お試しください。"
        }
    }
}

enum AccountDeletionUI {
    static let accountButtonTitle = "アカウントを削除"
    static let requiredConfirmation = "削除"
    static let subscriptionManagementURL = URL(string: "https://apps.apple.com/account/subscriptions")!
    static let localEraseFailureMessage = "サーバー上のアカウントは削除されましたが、この端末の資料を消去できませんでした。アプリを終了して、もう一度開いてください。"

    static func canSubmit(confirmation: String, isBusy: Bool) -> Bool {
        confirmation == requiredConfirmation && !isBusy
    }

    static func canDismiss(isBusy: Bool) -> Bool { !isBusy }
}

enum AccountLocalPreferences {
    /// Clears everything the account owned, except settings that belong to the
    /// device rather than the account: the language, and whether this device
    /// syncs with iCloud. The sync choice must survive: with it gone, the next
    /// launch finds the library on disk and turns sync *on*, which would pull
    /// whatever old data is still in iCloud back into an account the student
    /// just deleted.
    static func clear(defaults: UserDefaults = .standard) {
        let preservedLanguage = defaults.string(forKey: "appLanguage")
        let preservedICloudSync = defaults.object(forKey: ICloudSyncPreference.defaultsKey) as? Bool
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
        if let preservedLanguage { defaults.set(preservedLanguage, forKey: "appLanguage") }
        if let preservedICloudSync { defaults.set(preservedICloudSync, forKey: ICloudSyncPreference.defaultsKey) }
    }
}

@MainActor
enum AccountDeletionWorkflow {
    enum Result: Equatable {
        case success
        case serverFailure
        case localFailure(String)
    }

    static func run(
        authentication: AuthenticationStore,
        eraseLocalData: () throws -> Void,
        clearPreferences: () -> Void = { AccountLocalPreferences.clear() }
    ) async -> Result {
        guard await authentication.requestAccountDeletion() else { return .serverFailure }
        do {
            try eraseLocalData()
            clearPreferences()
            authentication.finishAccountDeletion()
            return .success
        } catch {
            return .localFailure(AccountDeletionUI.localEraseFailureMessage)
        }
    }
}

@MainActor
enum AccountDataEraser {
    static func eraseAll(from context: ModelContext) throws {
        try context.delete(model: MCPImportReceipt.self)
        try context.delete(model: AIReviewItem.self)
        try context.delete(model: AIChatMessage.self)
        try context.delete(model: AIChatThread.self)
        try context.delete(model: Flashcard.self)
        try context.delete(model: FlashcardDeck.self)
        try context.delete(model: CalendarEvent.self)
        try context.delete(model: StudyActivity.self)
        try context.delete(model: PageElement.self)
        try context.delete(model: NotePage.self)
        try context.delete(model: Notebook.self)
        try context.delete(model: SlideElement.self)
        try context.delete(model: SlidePlaceholder.self)
        try context.delete(model: SlideLayoutTemplate.self)
        try context.delete(model: SlideMaster.self)
        try context.delete(model: Slide.self)
        try context.delete(model: SlideDeck.self)
        try context.delete(model: DocumentComment.self)
        try context.delete(model: DocumentChangeRecord.self)
        try context.delete(model: DocumentFootnote.self)
        try context.delete(model: DocumentTableCell.self)
        try context.delete(model: DocumentTableRow.self)
        try context.delete(model: DocumentHeaderFooter.self)
        try context.delete(model: DocumentBlock.self)
        try context.delete(model: TextDocument.self)
        try context.delete(model: Folder.self)
        try context.save()
    }
}
