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

    /// The nonce of the sign-in in progress (see `SignInNonce`). SwiftUI's
    /// `SignInWithAppleButton` builds its request in its own closure and only hands the
    /// result back later, so the nonce is kept here between the two.
    private static let pendingNonce = PendingSignInNonce()

    /// Prepares an Apple ID request: the scopes, and a fresh nonce whose hash Apple will
    /// put in the ID token. Call it for every request, from `signIn()` and from the
    /// button's `onRequest`.
    nonisolated static func prepare(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.email]
        let nonce = SignInNonce.make()
        pendingNonce.store(nonce)
        request.nonce = nonce.hashed
    }

    /// Runs the native Sign in with Apple flow itself end to end, via this
    /// service's own ASAuthorizationController. Use this when nothing else
    /// has already obtained an authorization.
    @discardableResult
    func signIn() async throws -> (subject: String, email: String?) {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        Self.prepare(request)
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
        // Without a stored nonce (a request not built by `prepare`) the sign-in goes
        // without one, which a server that does not require nonces still accepts.
        let nonce = Self.pendingNonce.take()?.raw
        let token = try await exchange(identityToken: identityToken, randomValue: MCPCloudCredentials.makeRandomValue(), nonce: nonce)
        MCPCloudCredentials.save(token)
        return (credential.user, credential.email)
    }

    /// POST /api/auth/apple: same "<issued-at epoch>.<random>" token format
    /// MCPCloudCredentials.makeToken() produces, just minted server-side here
    /// from the random half this device supplies.
    private func exchange(identityToken: String, randomValue: String, nonce: String?) async throws -> String {
        try await exchange(
            identityToken: identityToken,
            randomValue: randomValue,
            nonce: nonce,
            endpoint: endpoint,
            session: .shared
        )
    }

    /// `randomValue` is still sent so a server from before the Worker made the secret half
    /// of the token itself keeps working; the current server ignores it. `nonce`, when
    /// present, is the raw nonce whose hash is in the ID token.
    func exchange(
        identityToken: String,
        randomValue: String,
        nonce: String? = nil,
        endpoint: URL,
        session: URLSession
    ) async throws -> String {
        var request = URLRequest(url: endpoint.appending(path: "api/auth/apple"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ExchangeRequest(identityToken: identityToken, randomValue: randomValue, nonce: nonce))
        let (data, response) = try await session.dataNoticing(for: request)
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

private struct ExchangeRequest: Encodable { let identityToken: String; let randomValue: String; let nonce: String? }
private struct ExchangeResponse: Decodable { let token: String }
