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

    private func login429or503(status: Int, headers: [String: String]?, body: String) async -> LocalAuthError? {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers))
            return (response, Data(body.utf8))
        }
        do {
            _ = try await LocalAuthService.login(
                email: "a@example.com", password: "pass", randomValue: "r",
                endpoint: endpoint, session: session()
            )
            XCTFail("成功扱いにしてはいけません")
            return nil
        } catch let error as LocalAuthError {
            return error
        } catch {
            XCTFail("想定外のエラー: \(error)")
            return nil
        }
    }

    func testTooManyAttemptsCarriesTheRetryAfterHeader() async {
        let error = await login429or503(status: 429, headers: ["Retry-After": "15"], body: #"{"error":"Too many attempts. Please try again later.","retryAfterSeconds":15}"#)
        XCTAssertEqual(error, .tooManyAttempts(retryAfter: 15))
    }

    func testTooManyAttemptsFallsBackToTheBodyAndThenToNothing() async {
        let fromBody = await login429or503(status: 429, headers: nil, body: #"{"retryAfterSeconds":90}"#)
        XCTAssertEqual(fromBody, .tooManyAttempts(retryAfter: 90))
        // The per-network limiter in front of the app sends neither.
        let nothing = await login429or503(status: 429, headers: nil, body: #"{"error":"Too many attempts. Please try again later."}"#)
        XCTAssertEqual(nothing, .tooManyAttempts(retryAfter: nil))
        let garbage = await login429or503(status: 429, headers: ["Retry-After": "soon"], body: "<html>")
        XCTAssertEqual(garbage, .tooManyAttempts(retryAfter: nil))
    }

    func testAServerBusyAnswerIsNotAWrongPassword() async {
        let error = await login429or503(status: 503, headers: ["Retry-After": "2"], body: #"{"error":"The server is busy. Please try again in a moment."}"#)
        XCTAssertEqual(error, .serverBusy(retryAfter: 2))
    }

    func testTheWaitIsExplainedInSecondsThenMinutes() {
        XCTAssertEqual(LocalAuthError.waitSentence(15), "あと約15秒お待ちください。")
        XCTAssertEqual(LocalAuthError.waitSentence(14.2), "あと約15秒お待ちください。")
        XCTAssertEqual(LocalAuthError.waitSentence(59), "あと約59秒お待ちください。")
        XCTAssertEqual(LocalAuthError.waitSentence(60), "あと約1分お待ちください。")
        XCTAssertEqual(LocalAuthError.waitSentence(900), "あと約15分お待ちください。")
        XCTAssertEqual(LocalAuthError.waitSentence(61), "あと約2分お待ちください。")
        XCTAssertEqual(LocalAuthError.waitSentence(nil), "しばらく待ってから、もう一度お試しください。")
        XCTAssertEqual(LocalAuthError.waitSentence(0), "しばらく待ってから、もう一度お試しください。")
    }

    func testNeitherMessageSaysThePasswordIsWrong() {
        for error in [LocalAuthError.tooManyAttempts(retryAfter: 30), .tooManyAttempts(retryAfter: nil), .serverBusy(retryAfter: 2)] {
            XCTAssertFalse((error.errorDescription ?? "").contains("違います"), "\(error)")
        }
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
