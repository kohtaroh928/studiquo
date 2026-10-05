import XCTest
@testable import studiquo

final class PasskeyHTTPClientTests: XCTestCase {
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

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testPostBuildsPasskeyRequestAndDecodesResponse() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/api/passkeys/register/options")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, Data(#"{"transaction":"tx-1"}"#.utf8))
        }

        let result: ResponseBody = try await PasskeyHTTPClient.post(
            endpoint: URL(string: "https://example.test")!,
            path: "api/passkeys/register/options",
            body: RequestBody(email: "student@example.com"),
            bearer: "session-token",
            session: session()
        )

        XCTAssertEqual(result, ResponseBody(transaction: "tx-1"))
    }

    func testPostOmitsAuthorizationWhenBearerIsNil() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, Data(#"{"transaction":"anonymous"}"#.utf8))
        }

        let result: ResponseBody = try await PasskeyHTTPClient.post(
            endpoint: URL(string: "https://example.test")!, path: "login",
            body: RequestBody(email: ""), bearer: nil, session: session()
        )
        XCTAssertEqual(result.transaction, "anonymous")
    }

    func testPostRejectsServerFailure() async {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
            ))
            return (response, Data())
        }

        do {
            let _: ResponseBody = try await PasskeyHTTPClient.post(
                endpoint: URL(string: "https://example.test")!, path: "verify",
                body: RequestBody(email: ""), bearer: nil, session: session()
            )
            XCTFail("500応答は成功扱いにしてはいけません")
        } catch let error as PasskeyError {
            guard case .serverRejected = error else { return XCTFail("想定外のエラー: \(error)") }
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }
    }

    func testPostRejectsMalformedSuccessResponse() async {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, Data(#"{"transaction":false}"#.utf8))
        }

        do {
            let _: ResponseBody = try await PasskeyHTTPClient.post(
                endpoint: URL(string: "https://example.test")!, path: "options",
                body: RequestBody(email: ""), bearer: nil, session: session()
            )
            XCTFail("不正なJSON応答は成功扱いにしてはいけません")
        } catch is DecodingError {
            // Expected.
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }
    }
}
