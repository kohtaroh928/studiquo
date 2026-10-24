import Foundation

/// Email/password login against the server (local-auth.js). The password is
/// sent once per attempt, over HTTPS, and never stored on this device — the
/// server holds only a salted hash, the same standard model every mainstream
/// app uses. Mirrors AppleSignInService/GoogleSignInService's plain
/// POST-and-decode shape and token contract.
enum LocalAuthService {
    private static var endpoint: URL { MCPCloudCredentials.configuredEndpoint() ?? URL(string: WorkerAIProvider.defaultEndpoint)! }

    static func login(email: String, password: String) async throws -> String {
        try await login(
            email: email,
            password: password,
            randomValue: MCPCloudCredentials.makeRandomValue(),
            endpoint: endpoint,
            session: .shared
        )
    }

    static func login(
        email: String,
        password: String,
        randomValue: String,
        endpoint: URL,
        session: URLSession
    ) async throws -> String {
        var request = URLRequest(url: endpoint.appending(path: "api/auth/local/login"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LoginRequest(
            email: email, password: password, randomValue: randomValue
        ))
        let (data, response) = try await session.dataNoticing(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            if let http = response as? HTTPURLResponse {
                let retryAfter = Self.retryAfterSeconds(http, body: data)
                // 429: too many attempts for this address or network, and the
                // server is not checking passwords for a while. 503: it was too
                // busy to check this one, and did not count it against anyone.
                // Neither says anything about whether the password was right.
                if http.statusCode == 429 { throw LocalAuthError.tooManyAttempts(retryAfter: retryAfter) }
                if http.statusCode == 503 {
                    // The operator has paused the service or sign-in on purpose: the banner says so,
                    // and retrying in a few seconds (what a busy server gets) would only repeat it.
                    if let notice = ServerNotice.parse(statusCode: 503, retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"), body: data) {
                        throw LocalAuthError.servicePaused(message: notice.message)
                    }
                    throw LocalAuthError.serverBusy(retryAfter: retryAfter)
                }
                if http.statusCode == 403, PasskeyRequired.isIn(body: data) { throw LocalAuthError.passkeyRequired }
                if http.statusCode == 409, AccountDeleting.isIn(body: data) { throw LocalAuthError.accountDeleting }
            }
            throw LocalAuthError.rejected
        }
        return try JSONDecoder().decode(LoginResponse.self, from: data).token
    }

    /// How long the server asked us to wait: the `Retry-After` header, else the
    /// `retryAfterSeconds` it also puts in the body. `nil` when it said nothing
    /// usable (the Cloudflare per-network limit sends neither).
    static func retryAfterSeconds(_ response: HTTPURLResponse, body: Data) -> TimeInterval? {
        if let header = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)), seconds > 0 {
            return seconds
        }
        if let parsed = try? JSONDecoder().decode(RetryBody.self, from: body), let seconds = parsed.retryAfterSeconds, seconds > 0 {
            return TimeInterval(seconds)
        }
        return nil
    }
}

enum LocalAuthError: LocalizedError, Equatable {
    case rejected
    /// Too many sign-in attempts in a row; the server is making this wait.
    case tooManyAttempts(retryAfter: TimeInterval?)
    /// The server was too busy to check the password (nothing was counted).
    case serverBusy(retryAfter: TimeInterval?)
    /// The account has a passkey, so a password is no longer accepted.
    case passkeyRequired
    /// The account was just deleted and the server is still finishing it.
    case accountDeleting
    /// The operator paused the service (maintenance) or sign-in. Not retried.
    case servicePaused(message: String)

    var errorDescription: String? {
        switch self {
        case .servicePaused(let message): message
        case .passkeyRequired: PasskeyRequired.message
        case .accountDeleting: AccountDeleting.message
        case .rejected:
            "メールアドレスまたはパスワードが違います。"
        case .tooManyAttempts(let retryAfter):
            "ログインの試行が続いたため、一時的に受け付けられません。" + Self.waitSentence(retryAfter)
        case .serverBusy:
            "サーバーが混み合っています。少し待ってから、もう一度お試しください。"
        }
    }

    /// "あと約15秒お待ちください。" / "あと約2分お待ちください。", or a plain request to wait
    /// when the server didn't say how long.
    static func waitSentence(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds > 0 else { return "しばらく待ってから、もう一度お試しください。" }
        if seconds < 60 { return "あと約\(Int(seconds.rounded(.up)))秒お待ちください。" }
        return "あと約\(Int((seconds / 60).rounded(.up)))分お待ちください。"
    }
}

private struct RetryBody: Decodable { let retryAfterSeconds: Int? }

private struct LoginRequest: Encodable { let email: String; let password: String; let randomValue: String }
private struct LoginResponse: Decodable { let token: String }

/// The account the person is signing in to was deleted a moment ago and the
/// server is still removing it (`code: "account_deleting"`, 409). It finishes by
/// itself, usually within the hour; signing up again works after that. Without
/// this the person saw the passkey of the account they had just deleted.
enum AccountDeleting {
    static let message = "このアカウントは削除の処理中です。しばらく(最長で1時間ほど)してから、もう一度お試しください。"

    static func isIn(body: Data) -> Bool {
        struct Body: Decodable { let code: String? }
        return (try? JSONDecoder().decode(Body.self, from: body))?.code == "account_deleting"
    }
}

/// The server refuses a password or e-mailed code for an account that has a
/// passkey (`code: "passkey_required"`).
enum PasskeyRequired {
    static let message = "このアカウントはパスキーでログインする設定です。「パスキーでログイン」を使ってください。パスキーが使えない場合は、メールをお送りしたので、案内に沿って48時間後にもう一度お試しください。"

    static func isIn(body: Data) -> Bool {
        struct Body: Decodable { let code: String? }
        return (try? JSONDecoder().decode(Body.self, from: body))?.code == "passkey_required"
    }
}
