import XCTest
@testable import studiquo

final class PasskeyServiceTests: XCTestCase {
    private struct RequestBody: Codable { let email: String }
    private struct ResponseBody: Codable, Equatable { let transaction: String }

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

    private let endpoint = URL(string: "https://example.test")!

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func stub(status: Int, body: String = "") {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            ))
            return (response, Data(body.utf8))
        }
    }

    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    // MARK: PasskeyReauth.isRequired

    func testReauthRequiredOn403WithReauthCode() {
        XCTAssertTrue(PasskeyReauth.isRequired(status: 403, body: Data(#"{"code":"reauth_required"}"#.utf8)))
    }

    func testReauthNotRequiredForOtherCodeOrStatus() {
        XCTAssertFalse(PasskeyReauth.isRequired(status: 403, body: Data(#"{"code":"forbidden"}"#.utf8)))
        XCTAssertFalse(PasskeyReauth.isRequired(status: 401, body: Data(#"{"code":"reauth_required"}"#.utf8)))
        XCTAssertFalse(PasskeyReauth.isRequired(status: 500, body: Data(#"{"code":"reauth_required"}"#.utf8)))
        XCTAssertFalse(PasskeyReauth.isRequired(status: nil, body: Data(#"{"code":"reauth_required"}"#.utf8)))
    }

    func testReauthNotRequiredForMissingEmptyOrMalformedBody() {
        XCTAssertFalse(PasskeyReauth.isRequired(status: 403, body: Data(#"{}"#.utf8)))
        XCTAssertFalse(PasskeyReauth.isRequired(status: 403, body: Data()))
        XCTAssertFalse(PasskeyReauth.isRequired(status: 403, body: Data("<html>".utf8)))
    }

    // MARK: PasskeyHTTPClient error mapping

    func testPostMapsReauthResponseToReauthRequired() async {
        stub(status: 403, body: #"{"code":"reauth_required"}"#)
        do {
            let _: ResponseBody = try await PasskeyHTTPClient.post(
                endpoint: endpoint, path: "api/passkeys/remove-all",
                body: RequestBody(email: ""), bearer: "t", session: session()
            )
            XCTFail("expected reauthRequired")
        } catch PasskeyError.reauthRequired {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPostMapsPlain403ToServerRejected() async {
        stub(status: 403, body: #"{"code":"forbidden"}"#)
        do {
            let _: ResponseBody = try await PasskeyHTTPClient.post(
                endpoint: endpoint, path: "p", body: RequestBody(email: ""), bearer: nil, session: session()
            )
            XCTFail("expected serverRejected")
        } catch PasskeyError.serverRejected {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: PasskeyService.hasPasskey

    func testHasPasskeyReturnsTrueWhenRegistered() async {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/api/passkeys/status")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, Data(#"{"registered":true}"#.utf8))
        }
        let result = await PasskeyService.hasPasskey(token: "session-token", endpoint: endpoint, session: session())
        XCTAssertEqual(result, true)
    }

    func testHasPasskeyReturnsFalseWhenNotRegistered() async {
        stub(status: 200, body: #"{"registered":false}"#)
        let result = await PasskeyService.hasPasskey(token: "t", endpoint: endpoint, session: session())
        XCTAssertEqual(result, false)
    }

    func testHasPasskeyReturnsNilWhenUnknown() async {
        // Non-200, malformed body, and network failure must never read as "no passkey".
        stub(status: 500, body: #"{"registered":false}"#)
        var result = await PasskeyService.hasPasskey(token: "t", endpoint: endpoint, session: session())
        XCTAssertNil(result)

        stub(status: 404)
        result = await PasskeyService.hasPasskey(token: "t", endpoint: endpoint, session: session())
        XCTAssertNil(result)

        stub(status: 200, body: "not json")
        result = await PasskeyService.hasPasskey(token: "t", endpoint: endpoint, session: session())
        XCTAssertNil(result)

        URLProtocolStub.handler = { _ in throw URLError(.notConnectedToInternet) }
        result = await PasskeyService.hasPasskey(token: "t", endpoint: endpoint, session: session())
        XCTAssertNil(result)
    }

    // MARK: PasskeyError

    func testEveryPasskeyErrorHasAMessage() {
        let errors: [PasskeyError] = [.cancelled, .reauthRequired, .invalidResponse, .notVerified, .serverRejected]
        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error)")
        }
        XCTAssertEqual(Set(errors.compactMap(\.errorDescription)).count, errors.count)
    }
}
