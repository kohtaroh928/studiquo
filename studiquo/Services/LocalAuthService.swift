import Foundation

/// Email/password login against the server (local-auth.js). The password is
/// sent once per attempt, over HTTPS, and never stored on this device — the
/// server holds only a salted hash, the same standard model every mainstream
/// app uses. Mirrors AppleSignInService/GoogleSignInService's plain
/// POST-and-decode shape and token contract.
enum LocalAuthService {
    private static var endpoint: URL { MCPCloudCredentials.configuredEndpoint() ?? URL(string: WorkerAIProvider.defaultEndpoint)! }

    static func login(email: String, password: String) async throws -> String {
        var request = URLRequest(url: endpoint.appending(path: "api/auth/local/login"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LoginRequest(
            email: email, password: password, randomValue: MCPCloudCredentials.makeRandomValue()
        ))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw LocalAuthError.rejected
        }
        return try JSONDecoder().decode(LoginResponse.self, from: data).token
    }
}

enum LocalAuthError: LocalizedError {
    case rejected
    var errorDescription: String? {
        "メールアドレスまたはパスワードが違います。"
    }
}

private struct LoginRequest: Encodable { let email: String; let password: String; let randomValue: String }
private struct LoginResponse: Decodable { let token: String }
