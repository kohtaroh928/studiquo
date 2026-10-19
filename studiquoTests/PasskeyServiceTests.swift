import XCTest
@testable import studiquo

@MainActor
final class PasskeyServiceTests: XCTestCase {
    private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
        static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let (response, data) = try Self.handler?(request) ?? { throw URLError(.badServerResponse) }()
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testHasPasskeyReturnsTrueOrFalseOnHTTP200() async throws {
        let endpoint = URL(string: "https://example.test")!

        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/api/passkeys/status")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, Data(#"{"registered":true}"#.utf8))
        }
        let registered = await PasskeyService.hasPasskey(token: "token-123", endpoint: endpoint, session: stubSession())
        XCTAssertEqual(registered, true)

        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, Data(#"{"registered":false}"#.utf8))
        }
        let notRegistered = await PasskeyService.hasPasskey(token: "token-123", endpoint: endpoint, session: stubSession())
        XCTAssertEqual(notRegistered, false)
    }

    func testHasPasskeyReturnsNilOnNetworkFailureOrServerErrorSoOfflineIsNeverMistakenForNoPasskey() async {
        let endpoint = URL(string: "https://example.test")!

        URLProtocolStub.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let offline = await PasskeyService.hasPasskey(token: "token-123", endpoint: endpoint, session: stubSession())
        XCTAssertNil(offline, "offline must return nil, never false")

        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
            ))
            return (response, Data(#"{"error":"internal"}"#.utf8))
        }
        let serverError = await PasskeyService.hasPasskey(token: "token-123", endpoint: endpoint, session: stubSession())
        XCTAssertNil(serverError)

        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, Data("not-json".utf8))
        }
        let malformed = await PasskeyService.hasPasskey(token: "token-123", endpoint: endpoint, session: stubSession())
        XCTAssertNil(malformed)
    }

    func testPasskeyReauthAndEmailCodePredicatesMatchExact403Codes() {
        let reauthBody = Data(#"{"error":"Passkey required","code":"reauth_required"}"#.utf8)
        XCTAssertTrue(PasskeyReauth.isRequired(status: 403, body: reauthBody))
        XCTAssertFalse(PasskeyReauth.isRequired(status: 401, body: reauthBody))
        XCTAssertFalse(PasskeyReauth.isRequired(status: 403, body: Data(#"{"code":"other"}"#.utf8)))
        XCTAssertFalse(PasskeyReauth.isRequired(status: nil, body: reauthBody))

        let emailCodeBody = Data(#"{"error":"Confirm email","code":"email_code_required"}"#.utf8)
        XCTAssertTrue(PasskeyEmailCode.isRequired(status: 403, body: emailCodeBody))
        XCTAssertFalse(PasskeyEmailCode.isRequired(status: 403, body: reauthBody))
        XCTAssertFalse(PasskeyEmailCode.isRequired(status: 200, body: emailCodeBody))
    }

    func testPasskeyHTTPClientMapsReauthRequiredToDedicatedError() async {
        struct Empty: Codable {}
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil
            ))
            return (response, Data(#"{"error":"Reauth","code":"reauth_required"}"#.utf8))
        }

        do {
            let _: Empty = try await PasskeyHTTPClient.post(
                endpoint: URL(string: "https://example.test")!,
                path: "api/passkeys/remove-all",
                body: Empty(),
                bearer: "token",
                session: stubSession()
            )
            XCTFail("Expected PasskeyError.reauthRequired")
        } catch let error as PasskeyError {
            guard case .reauthRequired = error else {
                return XCTFail("Unexpected PasskeyError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEveryPasskeyErrorProvidesLocalizedUserFacingDescription() {
        let allErrors: [PasskeyError] = [
            .cancelled,
            .emailCodeRequired,
            .wrongEmailCode,
            .reauthRequired,
            .invalidResponse,
            .notVerified,
            .serverRejected,
        ]
        for err in allErrors {
            let description = err.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty, "\(err) must provide a non-empty localized description")
        }
    }
}
