import AuthenticationServices
import Foundation
import UIKit

@MainActor
final class PasskeyService: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static let shared = PasskeyService()

    private let relyingPartyIdentifier = "studiquo-mcp.studiquo-mcp-server.workers.dev"
    private let endpoint = URL(string: "https://studiquo-mcp.studiquo-mcp-server.workers.dev")!
    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    func register(email: String, token: String) async throws {
        let envelope: RegistrationOptionsEnvelope = try await post(
            path: "api/passkeys/register/options", body: ["email": email], bearer: token
        )
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyIdentifier)
        let request = provider.createCredentialRegistrationRequest(
            challenge: try envelope.options.challenge.base64URLData(),
            name: email,
            userID: try envelope.options.user.id.base64URLData()
        )
        request.userVerificationPreference = .required
        let authorization = try await perform(request)
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestation = credential.rawAttestationObject else { throw PasskeyError.invalidResponse }
        let response = RegistrationCredential(
            id: credential.credentialID.base64URLEncodedString(),
            rawId: credential.credentialID.base64URLEncodedString(),
            response: .init(
                clientDataJSON: credential.rawClientDataJSON.base64URLEncodedString(),
                attestationObject: attestation.base64URLEncodedString(),
                transports: ["internal"]
            ),
            type: "public-key",
            authenticatorAttachment: "platform",
            clientExtensionResults: [:]
        )
        let _: RegistrationResult = try await post(
            path: "api/passkeys/register/verify",
            body: RegistrationVerification(transaction: envelope.transaction, credential: response),
            bearer: token
        )
    }

    /// Returns the account's email and a freshly minted studiquo cloud
    /// token — a successful passkey assertion is itself proof of identity,
    /// so the server mints a real session here, same as it does for
    /// Apple/Google/local-password sign-in.
    func login() async throws -> (email: String, token: String) {
        let envelope: AuthenticationOptionsEnvelope = try await post(
            path: "api/passkeys/login/options", body: EmptyBody(), bearer: nil
        )
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyIdentifier)
        let request = provider.createCredentialAssertionRequest(challenge: try envelope.options.challenge.base64URLData())
        request.userVerificationPreference = .required
        let authorization = try await perform(request)
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw PasskeyError.invalidResponse
        }
        let id = credential.credentialID.base64URLEncodedString()
        let response = AuthenticationCredential(
            id: id,
            rawId: id,
            response: .init(
                clientDataJSON: credential.rawClientDataJSON.base64URLEncodedString(),
                authenticatorData: credential.rawAuthenticatorData.base64URLEncodedString(),
                signature: credential.signature.base64URLEncodedString(),
                userHandle: credential.userID.base64URLEncodedString()
            ),
            type: "public-key",
            authenticatorAttachment: "platform",
            clientExtensionResults: [:]
        )
        let result: AuthenticationResult = try await post(
            path: "api/passkeys/login/verify",
            body: AuthenticationVerification(transaction: envelope.transaction, credential: response, randomValue: MCPCloudCredentials.makeRandomValue()),
            bearer: nil
        )
        guard result.authenticated else { throw PasskeyError.notVerified }
        return (result.email, result.token)
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

    private func post<Response: Decodable, Body: Encodable>(
        path: String, body: Body, bearer: String?
    ) async throws -> Response {
        var request = URLRequest(url: endpoint.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw PasskeyError.serverRejected
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

enum PasskeyError: LocalizedError {
    case invalidResponse, notVerified, serverRejected
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "パスキーの応答を読み取れませんでした。"
        case .notVerified: "パスキーを確認できませんでした。"
        case .serverRejected: "パスキーサーバーに接続できませんでした。"
        }
    }
}

private struct EmptyBody: Codable {}
private struct PublicKeyUser: Codable { let id: String }
private struct PublicKeyOptions: Codable { let challenge: String; let user: PublicKeyUser }
private struct AuthenticationPublicKeyOptions: Codable { let challenge: String }
private struct RegistrationOptionsEnvelope: Codable { let transaction: String; let options: PublicKeyOptions }
private struct AuthenticationOptionsEnvelope: Codable { let transaction: String; let options: AuthenticationPublicKeyOptions }
private struct RegistrationResult: Codable { let registered: Bool }
private struct AuthenticationResult: Codable { let authenticated: Bool; let email: String; let token: String }

private struct RegistrationCredential: Codable {
    struct Response: Codable { let clientDataJSON: String; let attestationObject: String; let transports: [String] }
    let id: String; let rawId: String; let response: Response; let type: String
    let authenticatorAttachment: String; let clientExtensionResults: [String: String]
}
private struct AuthenticationCredential: Codable {
    struct Response: Codable {
        let clientDataJSON: String; let authenticatorData: String; let signature: String; let userHandle: String
    }
    let id: String; let rawId: String; let response: Response; let type: String
    let authenticatorAttachment: String; let clientExtensionResults: [String: String]
}
private struct RegistrationVerification: Codable { let transaction: String; let credential: RegistrationCredential }
private struct AuthenticationVerification: Codable { let transaction: String; let credential: AuthenticationCredential; let randomValue: String }

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    func base64URLData() throws -> Data {
        var value = replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { throw PasskeyError.invalidResponse }
        return data
    }
}
