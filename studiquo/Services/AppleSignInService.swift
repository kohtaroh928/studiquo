import AuthenticationServices
import Foundation
import UIKit

/// Sign in with Apple, mirroring PasskeyService's ASAuthorizationController
/// delegate pattern: runs the native Apple ID flow, exchanges the resulting
/// identityToken with the server for a studiquo cloud token, and saves that
/// token through the same Keychain path every other cloud token goes through.
@MainActor
final class AppleSignInService: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static let shared = AppleSignInService()

    private var endpoint: URL { MCPCloudCredentials.configuredEndpoint() ?? URL(string: WorkerAIProvider.defaultEndpoint)! }
    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    /// Runs the native Sign in with Apple flow itself end to end, via this
    /// service's own ASAuthorizationController. Use this when nothing else
    /// has already obtained an authorization.
    @discardableResult
    func signIn() async throws -> (subject: String, email: String?) {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.email]
        let authorization = try await perform(request)
        return try await completeSignIn(with: authorization)
    }

    /// Finishes a Sign in with Apple flow whose ASAuthorizationController was
    /// already run elsewhere — SwiftUI's `SignInWithAppleButton` performs its
    /// own request internally and only hands back the finished result, so the
    /// button's `onCompletion` calls this directly instead of `signIn()`.
    /// Calling `signIn()` there would start a second, redundant native
    /// authorization prompt on top of the one the button already completed.
    ///
    /// Returns Apple's stable per-app user identifier (`credential.user`,
    /// present on every sign-in) and the email (present only on the user's
    /// very first authorization for this app, nil afterward) — the caller
    /// needs the identifier to recognize a returning Apple sign-in locally,
    /// since nothing else this service does persists that fact.
    @discardableResult
    func completeSignIn(with authorization: ASAuthorization) async throws -> (subject: String, email: String?) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8) else {
            throw AppleSignInError.invalidResponse
        }
        let token = try await exchange(identityToken: identityToken, randomValue: MCPCloudCredentials.makeRandomValue())
        MCPCloudCredentials.save(token)
        return (credential.user, credential.email)
    }

    /// POST /api/auth/apple: same "<issued-at epoch>.<random>" token format
    /// MCPCloudCredentials.makeToken() produces, just minted server-side here
    /// from the random half this device supplies.
    private func exchange(identityToken: String, randomValue: String) async throws -> String {
        var request = URLRequest(url: endpoint.appending(path: "api/auth/apple"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ExchangeRequest(identityToken: identityToken, randomValue: randomValue))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw AppleSignInError.serverRejected
        }
        return try JSONDecoder().decode(ExchangeResponse.self, from: data).token
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

enum AppleSignInError: LocalizedError {
    case invalidResponse, serverRejected
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Appleのサインイン応答を読み取れませんでした。"
        case .serverRejected: "サインインサーバーに接続できませんでした。"
        }
    }
}

private struct ExchangeRequest: Encodable { let identityToken: String; let randomValue: String }
private struct ExchangeResponse: Decodable { let token: String }
