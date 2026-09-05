import Foundation
import Security
import AuthenticationServices

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
    @Published private(set) var isPasskeyBusy = false
    @Published private(set) var isAppleSignInBusy = false
    @Published private(set) var isGoogleSignInBusy = false
    @Published private(set) var isEmailVerifyBusy = false
    @Published private(set) var isLoginBusy = false

    private let sessionAccount = "session"
    private let service: String
    private let onboardingKey = "authenticationOnboardingComplete"
    private let passkeyIdentityAccount = "passkey-identity"
    private let oauthIdentityAccount = "oauth-identity"
    private let now: () -> Date
    /// Email + new password held only in memory between `beginAccountCreation`
    /// and a successful `confirmEmailVerification` — nothing is written to
    /// Keychain until the code is confirmed, so an abandoned sign-up (or
    /// password reset) leaves no trace on disk. The server, not this device,
    /// owns the account: this is only ever a request to set the password for
    /// a now-verified email, which covers both initial signup and "forgot
    /// password" identically (see EmailVerificationService.confirmCode).
    private var pendingSignUp: (email: String, password: String)?

    /// `service`/`now` are overridable so tests can use an isolated Keychain
    /// service and a fake clock.
    init(service: String = "com.yabuko.studiquo.authentication", now: @escaping () -> Date = Date.init) {
        self.service = service
        self.now = now
        restore()
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
            errorMessage = ""
            state = UserDefaults.standard.bool(forKey: onboardingKey) ? .authenticated : .onboarding
            return true
        } catch {
            errorMessage = "メールアドレスまたはパスワードが違います。"
            return false
        }
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: onboardingKey)
        state = .authenticated
    }

    func logout() {
        delete(account: sessionAccount)
        state = .needsLogin
        // Best-effort and non-blocking: local sign-out must not wait on the network.
        Task { await MCPCloudCredentials.revoke() }
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
            errorMessage = ""
            state = UserDefaults.standard.bool(forKey: onboardingKey) ? .authenticated : .onboarding
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
            errorMessage = ""
            state = UserDefaults.standard.bool(forKey: onboardingKey) ? .authenticated : .onboarding
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
                errorMessage = ""
                state = UserDefaults.standard.bool(forKey: onboardingKey) ? .authenticated : .onboarding
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
            errorMessage = ""
            state = UserDefaults.standard.bool(forKey: onboardingKey) ? .authenticated : .onboarding
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
        state = UserDefaults.standard.bool(forKey: onboardingKey) ? .authenticated : .onboarding
    }

    private func createSession() {
        guard let expiresAt = Calendar.current.date(byAdding: .month, value: 6, to: Date()) else { return }
        _ = save(SessionRecord(token: UUID().uuidString, expiresAt: expiresAt), account: sessionAccount)
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
