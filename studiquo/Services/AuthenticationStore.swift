import CryptoKit
import Foundation
import Security
import AuthenticationServices

@MainActor
final class AuthenticationStore: ObservableObject {
    enum State: Equatable {
        case needsAccount
        case needsLogin
        case onboarding
        case authenticated
    }

    @Published private(set) var state: State = .needsAccount
    @Published var errorMessage = ""
    @Published private(set) var isPasskeyBusy = false

    private let credentialsAccount = "credentials"
    private let sessionAccount = "session"
    private let service = "com.yabuko.studiquo.authentication"
    private let onboardingKey = "authenticationOnboardingComplete"
    private let passkeyIdentityAccount = "passkey-identity"

    init() { restore() }

    var email: String {
        credentials()?.email ?? passkeyIdentity()?.email ?? ""
    }

    func createAccount(email: String, password: String) -> Bool {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count <= 254, normalized.contains("@"), normalized.contains(".") else {
            errorMessage = "正しいメールアドレスを入力してください。"
            return false
        }
        guard password.count >= 8, password.count <= 1_024 else {
            errorMessage = "パスワードは8文字以上にしてください。"
            return false
        }
        let salt = randomData(count: 24)
        let record = CredentialRecord(email: normalized, salt: salt, passwordHash: hash(password, salt: salt))
        guard save(record, account: credentialsAccount) else {
            errorMessage = "アカウントを保存できませんでした。"
            return false
        }
        createSession()
        errorMessage = ""
        state = .onboarding
        return true
    }

    func login(email: String, password: String) -> Bool {
        guard let record = credentials() else { return false }
        guard password.count <= 1_024,
              record.email == email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              constantTimeEqual(hash(password, salt: record.salt), record.passwordHash) else {
            errorMessage = "メールアドレスまたはパスワードが違います。"
            return false
        }
        createSession()
        errorMessage = ""
        state = UserDefaults.standard.bool(forKey: onboardingKey) ? .authenticated : .onboarding
        return true
    }

    func resetPassword(email: String, newPassword: String) -> Bool {
        guard let old = credentials(), old.email == email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            errorMessage = "この端末に登録されたメールアドレスと一致しません。"
            return false
        }
        guard newPassword.count >= 8, newPassword.count <= 1_024 else {
            errorMessage = "新しいパスワードは8文字以上にしてください。"
            return false
        }
        let salt = randomData(count: 24)
        guard save(CredentialRecord(email: old.email, salt: salt, passwordHash: hash(newPassword, salt: salt)), account: credentialsAccount) else {
            errorMessage = "パスワードを更新できませんでした。"
            return false
        }
        createSession()
        errorMessage = ""
        state = UserDefaults.standard.bool(forKey: onboardingKey) ? .authenticated : .onboarding
        return true
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: onboardingKey)
        state = .authenticated
    }

    func logout() {
        delete(account: sessionAccount)
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
            let email = try await PasskeyService.shared.login()
            guard save(PasskeyIdentity(email: email), account: passkeyIdentityAccount) else {
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

    private func restore() {
        guard credentials() != nil || passkeyIdentity() != nil else {
            state = .needsAccount
            return
        }
        if let session: SessionRecord = load(account: sessionAccount), session.expiresAt > Date() {
            // Active use renews the six-month session.
            createSession()
            state = UserDefaults.standard.bool(forKey: onboardingKey) ? .authenticated : .onboarding
        } else {
            state = .needsLogin
        }
    }

    private func createSession() {
        guard let expiresAt = Calendar.current.date(byAdding: .month, value: 6, to: Date()) else { return }
        _ = save(SessionRecord(token: UUID().uuidString, expiresAt: expiresAt), account: sessionAccount)
    }

    private func credentials() -> CredentialRecord? { load(account: credentialsAccount) }
    private func passkeyIdentity() -> PasskeyIdentity? { load(account: passkeyIdentityAccount) }

    private func hash(_ password: String, salt: Data) -> Data {
        var data = salt
        data.append(Data(password.utf8))
        // Repeated hashing makes offline guessing meaningfully more expensive.
        var digest = Data(SHA256.hash(data: data))
        for _ in 0..<20_000 { digest = Data(SHA256.hash(data: digest + salt)) }
        return digest
    }

    private func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
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

private struct CredentialRecord: Codable {
    let email: String
    let salt: Data
    let passwordHash: Data
}

private struct SessionRecord: Codable {
    let token: String
    let expiresAt: Date
}

private struct PasskeyIdentity: Codable {
    let email: String
}
