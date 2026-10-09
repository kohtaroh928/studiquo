import XCTest
@testable import studiquo

final class EmailVerificationServiceTests: XCTestCase {
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

    func testSendCodeSendsEmailToExpectedEndpoint() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/api/auth/email/send-code")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.bodyData(from: request)) as? [String: String])
            XCTAssertEqual(json, ["email": "student@example.com"])
            return (try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)), Data())
        }

        try await EmailVerificationService.sendCode(
            email: "student@example.com", endpoint: endpoint, session: session()
        )
    }

    func testSendCodeRejectsServerFailure() async {
        // 429 has its own error now (see testSendingTooManyCodesIsItsOwnError);
        // an ordinary server failure is still just "could not send".
        URLProtocolStub.handler = { request in
            (try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)), Data())
        }
        do {
            try await EmailVerificationService.sendCode(email: "a@example.com", endpoint: endpoint, session: session())
            XCTFail("500応答は成功扱いにしてはいけません")
        } catch let error as EmailVerificationError {
            guard case .sendFailed = error else { return XCTFail("想定外のエラー: \(error)") }
        } catch { XCTFail("想定外のエラー: \(error)") }
    }

    func testConfirmCodeSendsAllFieldsAndReturnsToken() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.test/api/auth/email/confirm-code")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.bodyData(from: request)) as? [String: String])
            XCTAssertEqual(json["email"], "student@example.com")
            XCTAssertEqual(json["code"], "123456")
            XCTAssertEqual(json["password"], "secret-pass")
            XCTAssertEqual(json["randomValue"], "random-part")
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, Data(#"{"verified":true,"token":"cloud-token"}"#.utf8))
        }

        let token = try await EmailVerificationService.confirmCode(
            email: "student@example.com", code: "123456", password: "secret-pass",
            randomValue: "random-part", endpoint: endpoint, session: session()
        )
        XCTAssertEqual(token, "cloud-token")
    }

    func testWrongCodePreservesAttemptsRemaining() async {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil))
            return (response, Data(#"{"error":"wrong_code","attemptsRemaining":2}"#.utf8))
        }
        do {
            _ = try await EmailVerificationService.confirmCode(
                email: "a@example.com", code: "000000", password: "pass", randomValue: "r",
                endpoint: endpoint, session: session()
            )
            XCTFail("誤コードは成功扱いにしてはいけません")
        } catch let EmailVerificationError.wrongCode(attemptsRemaining) {
            XCTAssertEqual(attemptsRemaining, 2)
        } catch { XCTFail("想定外のエラー: \(error)") }
    }

    func testWrongCodeWithoutAttemptsDefaultsToZero() async {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil))
            return (response, Data(#"{"error":"expired"}"#.utf8))
        }
        do {
            _ = try await EmailVerificationService.confirmCode(
                email: "a@example.com", code: "000000", password: "pass", randomValue: "r",
                endpoint: endpoint, session: session()
            )
            XCTFail("期限切れコードは成功扱いにしてはいけません")
        } catch let EmailVerificationError.wrongCode(attemptsRemaining) {
            XCTAssertEqual(attemptsRemaining, 0)
        } catch { XCTFail("想定外のエラー: \(error)") }
    }

    func testBreachedPasswordBecomesPasswordBreached() async {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil))
            return (response, Data(#"{"error":"このパスワードは...","code":"password_breached"}"#.utf8))
        }
        do {
            _ = try await EmailVerificationService.confirmCode(
                email: "a@example.com", code: "123456", password: "password", randomValue: "r",
                endpoint: endpoint, session: session()
            )
            XCTFail("漏洩パスワードは成功扱いにしてはいけません")
        } catch let error as EmailVerificationError {
            guard case .passwordBreached = error else { return XCTFail("想定外のエラー: \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("情報漏えい"))
        } catch { XCTFail("想定外のエラー: \(error)") }
    }

    func testOtherBadRequestStaysConfirmFailed() async {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil))
            return (response, Data(#"{"error":"password is required."}"#.utf8))
        }
        do {
            _ = try await EmailVerificationService.confirmCode(
                email: "a@example.com", code: "123456", password: "pass", randomValue: "r",
                endpoint: endpoint, session: session()
            )
            XCTFail("400応答は成功扱いにしてはいけません")
        } catch let error as EmailVerificationError {
            guard case .confirmFailed = error else { return XCTFail("想定外のエラー: \(error)") }
        } catch { XCTFail("想定外のエラー: \(error)") }
    }

    private func status429(_ headers: [String: String]?, body: String, send: Bool) async -> EmailVerificationError? {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: headers))
            return (response, Data(body.utf8))
        }
        do {
            if send {
                try await EmailVerificationService.sendCode(email: "a@example.com", endpoint: endpoint, session: session())
            } else {
                _ = try await EmailVerificationService.confirmCode(
                    email: "a@example.com", code: "123456", password: "pass", randomValue: "r",
                    endpoint: endpoint, session: session()
                )
            }
            XCTFail("429は成功扱いにしてはいけません")
            return nil
        } catch let error as EmailVerificationError {
            return error
        } catch {
            XCTFail("想定外のエラー: \(error)")
            return nil
        }
    }

    func testSendingTooManyCodesIsItsOwnError() async {
        let plain = await status429(nil, body: #"{"error":"Too many attempts. Please try again later."}"#, send: true)
        XCTAssertEqual(plain, .tooManySends(retryAfter: nil))
        let timed = await status429(["Retry-After": "90"], body: "{}", send: true)
        XCTAssertEqual(timed, .tooManySends(retryAfter: 90))
    }

    func testTryingTooManyCodesIsItsOwnErrorAndNotAWrongCode() async {
        let plain = await status429(nil, body: #"{"error":"Too many attempts. Please try again later."}"#, send: false)
        XCTAssertEqual(plain, .tooManyConfirmations(retryAfter: nil))
        let timed = await status429(["Retry-After": "30"], body: "{}", send: false)
        XCTAssertEqual(timed, .tooManyConfirmations(retryAfter: 30))
    }

    func testTheTooManyMessagesAreDistinctHonestAndNeverBlameTheCode() {
        let sends = EmailVerificationError.tooManySends(retryAfter: nil).errorDescription ?? ""
        let tries = EmailVerificationError.tooManyConfirmations(retryAfter: nil).errorDescription ?? ""
        XCTAssertNotEqual(sends, tries)
        XCTAssertTrue(sends.contains("しばらく待ってから"))
        XCTAssertTrue(tries.contains("しばらく待ってから"))
        XCTAssertFalse(tries.contains("正しくありません"), "the code was never looked at")
        XCTAssertEqual(
            EmailVerificationError.tooManySends(retryAfter: 120).errorDescription,
            "確認コードの送信が続いたため、いまは受け付けられません。あと約2分お待ちください。"
        )
    }

    func testOtherFailuresKeepTheirMessages() async {
        URLProtocolStub.handler = { request in
            (try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)), Data())
        }
        do {
            try await EmailVerificationService.sendCode(email: "a@example.com", endpoint: endpoint, session: session())
            XCTFail("成功扱いにしてはいけません")
        } catch let error as EmailVerificationError {
            XCTAssertEqual(error, .sendFailed)
        } catch { XCTFail("想定外のエラー: \(error)") }
    }

    func testMalformedSuccessResponseBecomesConfirmFailed() async {
        URLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (response, Data(#"{"verified":true}"#.utf8))
        }
        do {
            _ = try await EmailVerificationService.confirmCode(
                email: "a@example.com", code: "123456", password: "pass", randomValue: "r",
                endpoint: endpoint, session: session()
            )
            XCTFail("tokenのない応答は成功扱いにしてはいけません")
        } catch let error as EmailVerificationError {
            guard case .confirmFailed = error else { return XCTFail("想定外のエラー: \(error)") }
        } catch { XCTFail("想定外のエラー: \(error)") }
    }
}
