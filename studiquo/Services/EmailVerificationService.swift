import Foundation

/// Proves ownership of the email address a local (non-OAuth) account is
/// being created — or reset — with, by round-tripping a short code through
/// the user's inbox. Mirrors AppleSignInService/GoogleSignInService's plain
/// POST-and-decode shape. Unlike sendCode, confirmCode DOES mint a studiquo
/// cloud token on success: a correct code is the server's cue to set (or
/// replace) the account's password and sign this device in, exactly as if
/// it had just verified an Apple/Google identity token.
enum EmailVerificationService {
    private static var endpoint: URL { MCPCloudCredentials.configuredEndpoint() ?? URL(string: WorkerAIProvider.defaultEndpoint)! }

    static func sendCode(email: String) async throws {
        var request = URLRequest(url: endpoint.appending(path: "api/auth/email/send-code"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SendCodeRequest(email: email))
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw EmailVerificationError.sendFailed
        }
    }

    /// Throws `.wrongCode(attemptsRemaining:)` for an incorrect or expired
    /// code — the server still returns how many attempts are left before a
    /// fresh code is required — and `.confirmFailed` for anything else
    /// (network error, malformed response). Returns the freshly minted
    /// studiquo cloud token on success.
    static func confirmCode(email: String, code: String, password: String, randomValue: String) async throws -> String {
        var request = URLRequest(url: endpoint.appending(path: "api/auth/email/confirm-code"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ConfirmCodeRequest(email: email, code: code, password: password, randomValue: randomValue))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EmailVerificationError.confirmFailed }
        if 200..<300 ~= http.statusCode {
            guard let payload = try? JSONDecoder().decode(ConfirmSuccessResponse.self, from: data) else {
                throw EmailVerificationError.confirmFailed
            }
            return payload.token
        }
        if http.statusCode == 401, let payload = try? JSONDecoder().decode(ConfirmErrorResponse.self, from: data) {
            throw EmailVerificationError.wrongCode(attemptsRemaining: payload.attemptsRemaining ?? 0)
        }
        throw EmailVerificationError.confirmFailed
    }
}

enum EmailVerificationError: LocalizedError {
    case sendFailed
    case confirmFailed
    case wrongCode(attemptsRemaining: Int)

    var errorDescription: String? {
        switch self {
        case .sendFailed: "確認コードを送信できませんでした。"
        case .confirmFailed: "確認コードを確認できませんでした。"
        case .wrongCode(let attemptsRemaining):
            attemptsRemaining > 0
                ? "コードが正しくありません。残り\(attemptsRemaining)回試せます。"
                : "コードが正しくないか、期限切れです。もう一度送信してください。"
        }
    }
}

private struct SendCodeRequest: Encodable { let email: String }
private struct ConfirmCodeRequest: Encodable { let email: String; let code: String; let password: String; let randomValue: String }
private struct ConfirmSuccessResponse: Decodable { let verified: Bool; let token: String }
private struct ConfirmErrorResponse: Decodable { let error: String; let attemptsRemaining: Int? }
