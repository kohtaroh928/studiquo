import Foundation
import GoogleSignIn
import UIKit

/// Google Sign-In, mirroring AppleSignInService: runs the native Google
/// sign-in flow, exchanges the resulting ID token with the server for a
/// studiquo cloud token, and saves that token through the same Keychain path
/// every other cloud token goes through.
///
/// `GIDClientID`/`GIDServerClientID` in Info.plist configure the SDK, so no
/// manual `GIDConfiguration` is needed here. Setting `serverClientID` there
/// is what makes the returned ID token's audience the *server* client ID
/// (rather than this app's own iOS client ID) — the same audience
/// google-auth.js verifies against on the worker.
@MainActor
final class GoogleSignInService {
    static let shared = GoogleSignInService()

    private var endpoint: URL { MCPCloudCredentials.configuredEndpoint() ?? URL(string: WorkerAIProvider.defaultEndpoint)! }

    /// Returns Google's stable per-account identifier (`user.userID`, present
    /// on every sign-in) and the profile email — the caller needs the
    /// identifier to recognize a returning Google sign-in locally, since
    /// nothing else this service does persists that fact.
    @discardableResult
    func signIn() async throws -> (subject: String, email: String?) {
        guard let presentingViewController = Self.presentingViewController() else {
            throw GoogleSignInServiceError.noPresentingViewController
        }
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController)
        guard let idToken = result.user.idToken?.tokenString, let subject = result.user.userID else {
            throw GoogleSignInServiceError.invalidResponse
        }
        let token = try await exchange(idToken: idToken, randomValue: MCPCloudCredentials.makeRandomValue())
        MCPCloudCredentials.save(token)
        return (subject, result.user.profile?.email)
    }

    /// POST /api/auth/google: same "<issued-at epoch>.<random>" token format
    /// MCPCloudCredentials.makeToken() produces, just minted server-side here
    /// from the random half this device supplies — same contract as
    /// AppleSignInService.exchange(identityToken:randomValue:).
    private func exchange(idToken: String, randomValue: String) async throws -> String {
        var request = URLRequest(url: endpoint.appending(path: "api/auth/google"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ExchangeRequest(idToken: idToken, randomValue: randomValue))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw GoogleSignInServiceError.serverRejected
        }
        return try JSONDecoder().decode(ExchangeResponse.self, from: data).token
    }

    private static func presentingViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
    }
}

enum GoogleSignInServiceError: LocalizedError {
    case noPresentingViewController, invalidResponse, serverRejected
    var errorDescription: String? {
        switch self {
        case .noPresentingViewController: "サインイン画面を表示できませんでした。"
        case .invalidResponse: "Googleのサインイン応答を読み取れませんでした。"
        case .serverRejected: "サインインサーバーに接続できませんでした。"
        }
    }
}

private struct ExchangeRequest: Encodable { let idToken: String; let randomValue: String }
private struct ExchangeResponse: Decodable { let token: String }
