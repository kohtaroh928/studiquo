import Foundation

/// Email/password login against the server (local-auth.js). The password is
/// sent once per attempt, over HTTPS, and never stored on this device — the
/// server holds only a salted hash, the same standard model every mainstream
/// app uses. Mirrors AppleSignInService/GoogleSignInService's plain
/// POST-and-decode shape and token contract.
enum LocalAuthService {
    private static var endpoint: URL { MCPCloudCredentials.configuredEndpoint() ?? URL(string: WorkerAIProvider.defaultEndpoint)! }

    /// `captchaToken` is a solved Turnstile token, sent only after the server
    /// has asked for one (`LocalAuthError.captchaRequired`).
    static func login(email: String, password: String, captchaToken: String? = nil) async throws -> String {
        try await login(
            email: email,
            password: password,
            randomValue: MCPCloudCredentials.makeRandomValue(),
            endpoint: endpoint,
            session: .shared,
            captchaToken: captchaToken
        )
    }

    static func login(
        email: String,
        password: String,
        randomValue: String,
        endpoint: URL,
        session: URLSession,
        captchaToken: String? = nil
    ) async throws -> String {
        var request = URLRequest(url: endpoint.appending(path: "api/auth/local/login"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LoginRequest(
            email: email, password: password, randomValue: randomValue, captchaToken: captchaToken
        ))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            if let http = response as? HTTPURLResponse, let captcha = CaptchaServerResponse.parse(status: http.statusCode, data: data) {
                switch captcha {
                case .required(let siteKey): throw LocalAuthError.captchaRequired(siteKey: siteKey)
                case .unavailable: throw LocalAuthError.captchaUnavailable
                }
            }
            throw LocalAuthError.rejected
        }
        return try JSONDecoder().decode(LoginResponse.self, from: data).token
    }
}

enum LocalAuthError: LocalizedError {
    case rejected
    /// The server wants a solved CAPTCHA before it will check this attempt.
    case captchaRequired(siteKey: String)
    case captchaUnavailable

    var errorDescription: String? {
        switch self {
        case .rejected: "メールアドレスまたはパスワードが違います。"
        case .captchaRequired: "確認が必要です。"
        case .captchaUnavailable: "確認サービスに接続できません。しばらくしてからもう一度お試しください。"
        }
    }
}

private struct LoginRequest: Encodable { let email: String; let password: String; let randomValue: String; let captchaToken: String? }
private struct LoginResponse: Decodable { let token: String }
