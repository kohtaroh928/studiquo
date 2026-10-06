import Foundation

/// What the server asked for when it refused a request pending a CAPTCHA
/// (Cloudflare Turnstile, see turnstile.js on the server). The response
/// carries the public site key, so the app has nothing to configure.
enum CaptchaServerResponse: Equatable {
    case required(siteKey: String)
    case unavailable

    /// `nil` when `status`/`data` isn't a CAPTCHA refusal, i.e. an ordinary
    /// failure the caller should handle as before.
    static func parse(status: Int, data: Data) -> CaptchaServerResponse? {
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        switch (status, body.code) {
        case (403, "captcha_required"), (403, "captcha_failed"):
            guard let siteKey = body.siteKey, !siteKey.isEmpty else { return nil }
            return .required(siteKey: siteKey)
        case (503, "captcha_unavailable"):
            return .unavailable
        default:
            return nil
        }
    }

    private struct Body: Decodable { let code: String?; let siteKey: String? }
}

/// A CAPTCHA the person has to solve before an attempt can be retried, and
/// what to retry once they have. The widget's `action` must match what the
/// server verifies the token for, so a token can't be spent elsewhere.
struct CaptchaChallenge: Identifiable, Equatable {
    enum Continuation: Equatable {
        case login(email: String, password: String)
        case beginAccountCreation(email: String, password: String)
        case resendCode

        var action: String {
            switch self {
            case .login: "login"
            case .beginAccountCreation, .resendCode: "send-code"
            }
        }
    }

    let id = UUID()
    let siteKey: String
    let continuation: Continuation
    var action: String { continuation.action }
}
