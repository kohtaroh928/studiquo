import XCTest
@testable import studiquo

@MainActor
final class AppleSignInServiceTests: XCTestCase {
    private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
        static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let (response, data) = try Self.handler?(request) ?? {
                    throw URLError(.badServerResponse)
                }()
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

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testExchangeSendsExpectedRequestAndReturnsToken() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/base/api/auth/apple")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try Self.bodyData(from: request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(json["identityToken"], "apple-id-token")
            XCTAssertEqual(json["randomValue"], "random-part")
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, Data(#"{"token":"cloud-token"}"#.utf8))
        }

        let token = try await AppleSignInService.shared.exchange(
            identityToken: "apple-id-token",
            randomValue: "random-part",
            endpoint: URL(string: "https://example.test/base")!,
            session: session()
        )

        XCTAssertEqual(token, "cloud-token")
    }

    func testExchangeAcceptsAnySuccessfulHTTPStatus() async throws {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil
            ))
            return (response, Data(#"{"token":"created-token"}"#.utf8))
        }

        let token = try await AppleSignInService.shared.exchange(
            identityToken: "id", randomValue: "random",
            endpoint: URL(string: "https://example.test")!, session: session()
        )
        XCTAssertEqual(token, "created-token")
    }

    func testExchangeRejectsUnsuccessfulHTTPStatus() async {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            ))
            return (response, Data())
        }

        do {
            _ = try await AppleSignInService.shared.exchange(
                identityToken: "id", randomValue: "random",
                endpoint: URL(string: "https://example.test")!, session: session()
            )
            XCTFail("401応答は成功扱いにしてはいけません")
        } catch let error as AppleSignInError {
            guard case .serverRejected = error else {
                return XCTFail("想定外のエラー: \(error)")
            }
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }
    }

    func testExchangeRejectsMalformedSuccessfulResponse() async {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            ))
            return (response, Data(#"{"unexpected":true}"#.utf8))
        }

        do {
            _ = try await AppleSignInService.shared.exchange(
                identityToken: "id", randomValue: "random",
                endpoint: URL(string: "https://example.test")!, session: session()
            )
            XCTFail("tokenのない応答は成功扱いにしてはいけません")
        } catch is DecodingError {
            // Expected.
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }
    }
}
