import XCTest
@testable import studiquo

final class LocalAuthServiceTests: XCTestCase {
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
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }

    private let endpoint = URL(string: "https://example.test")!

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
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

    func testLoginSendsCredentialsAndRandomValue() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/api/auth/local/login")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.bodyData(from: request)) as? [String: String])
            XCTAssertEqual(json["email"], "student@example.com")
            XCTAssertEqual(json["password"], "password-123")
            XCTAssertEqual(json["randomValue"], "random-part")
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, Data(#"{"token":"session-token"}"#.utf8))
        }

        _ = try await LocalAuthService.login(
            email: "student@example.com", password: "password-123", randomValue: "random-part",
            endpoint: endpoint, session: session()
        )
    }

    func testSuccessfulLoginReturnsToken() async throws {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil))
            return (response, Data(#"{"token":"created-token"}"#.utf8))
        }
        let token = try await LocalAuthService.login(
            email: "a@example.com", password: "pass", randomValue: "r",
            endpoint: endpoint, session: session()
        )
        XCTAssertEqual(token, "created-token")
    }

    func testUnauthorizedLoginIsRejected() async {
        URLProtocolStub.handler = { request in
            (try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)), Data())
        }
        do {
            _ = try await LocalAuthService.login(
                email: "a@example.com", password: "wrong", randomValue: "r",
                endpoint: endpoint, session: session()
            )
            XCTFail("401応答は成功扱いにしてはいけません")
        } catch let error as LocalAuthError {
            guard case .rejected = error else { return XCTFail("想定外のエラー: \(error)") }
        } catch { XCTFail("想定外のエラー: \(error)") }
    }

    func testCaptchaTokenIsSentOnlyWhenGiven() async throws {
        var bodies: [[String: String]] = []
        URLProtocolStub.handler = { request in
            bodies.append(try XCTUnwrap(JSONSerialization.jsonObject(with: Self.bodyData(from: request)) as? [String: String]))
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, Data(#"{"token":"session-token"}"#.utf8))
        }
        _ = try await LocalAuthService.login(email: "a@example.com", password: "pass", randomValue: "r", endpoint: endpoint, session: session())
        _ = try await LocalAuthService.login(email: "a@example.com", password: "pass", randomValue: "r", endpoint: endpoint, session: session(), captchaToken: "solved-token")
        XCTAssertNil(bodies[0]["captchaToken"])
        XCTAssertEqual(bodies[1]["captchaToken"], "solved-token")
    }

    func testCaptchaRefusalCarriesTheSiteKey() async {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil))
            return (response, Data(#"{"error":"x","code":"captcha_required","siteKey":"0x4AAAA"}"#.utf8))
        }
        do {
            _ = try await LocalAuthService.login(email: "a@example.com", password: "pass", randomValue: "r", endpoint: endpoint, session: session())
            XCTFail("CAPTCHA要求は成功扱いにしてはいけません")
        } catch let error as LocalAuthError {
            guard case .captchaRequired(let siteKey) = error else { return XCTFail("想定外のエラー: \(error)") }
            XCTAssertEqual(siteKey, "0x4AAAA")
        } catch { XCTFail("想定外のエラー: \(error)") }
    }

    func testCaptchaServiceOutageIsDistinctFromAWrongPassword() async {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil))
            return (response, Data(#"{"error":"x","code":"captcha_unavailable","siteKey":"k"}"#.utf8))
        }
        do {
            _ = try await LocalAuthService.login(email: "a@example.com", password: "pass", randomValue: "r", endpoint: endpoint, session: session())
            XCTFail("成功扱いにしてはいけません")
        } catch let error as LocalAuthError {
            guard case .captchaUnavailable = error else { return XCTFail("想定外のエラー: \(error)") }
        } catch { XCTFail("想定外のエラー: \(error)") }
    }

    func testAPlain403IsStillJustRejected() async {
        URLProtocolStub.handler = { request in
            (try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)), Data(#"{"error":"nope"}"#.utf8))
        }
        do {
            _ = try await LocalAuthService.login(email: "a@example.com", password: "pass", randomValue: "r", endpoint: endpoint, session: session())
            XCTFail("成功扱いにしてはいけません")
        } catch let error as LocalAuthError {
            guard case .rejected = error else { return XCTFail("想定外のエラー: \(error)") }
        } catch { XCTFail("想定外のエラー: \(error)") }
    }

    func testMalformedSuccessfulResponseIsRejected() async {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, Data(#"{"token":false}"#.utf8))
        }
        do {
            _ = try await LocalAuthService.login(
                email: "a@example.com", password: "pass", randomValue: "r",
                endpoint: endpoint, session: session()
            )
            XCTFail("token形式が不正な応答は成功扱いにしてはいけません")
        } catch is DecodingError {
            // Expected.
        } catch { XCTFail("想定外のエラー: \(error)") }
    }
}
