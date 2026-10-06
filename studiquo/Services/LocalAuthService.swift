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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            if let http = response as? HTTPURLResponse {
                let retryAfter = Self.retryAfterSeconds(http, body: data)
                // 429: too many attempts for this address or network, and the
                // server is not checking passwords for a while. 503: it was too
                // busy to check this one, and did not count it against anyone.
                // Neither says anything about whether the password was right.
                if http.statusCode == 429 { throw LocalAuthError.tooManyAttempts(retryAfter: retryAfter) }
                if http.statusCode == 503 { throw LocalAuthError.serverBusy(retryAfter: retryAfter) }
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

    var errorDescription: String? {
        switch self {
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
