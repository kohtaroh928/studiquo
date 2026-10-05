import XCTest
@testable import studiquo

final class IssueReportServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(IssueReportURLProtocol.self)
        IssueReportURLProtocol.reset()
        UserDefaults.standard.removeObject(forKey: "mcpCloudEndpoint")
        UserDefaults.standard.removeObject(forKey: "appLanguage")
    }

    override func tearDown() {
        URLProtocol.unregisterClass(IssueReportURLProtocol.self)
        IssueReportURLProtocol.reset()
        UserDefaults.standard.removeObject(forKey: "appLanguage")
        super.tearDown()
    }

    func testSuccessfulSubmissionSendsAuthenticatedMetadataAndScreenshot() async throws {
        UserDefaults.standard.set("en", forKey: "appLanguage")
        IssueReportURLProtocol.respond(status: 201, json: ["reported": true, "id": "report-123"])

        let result = try await IssueReportService.submit(
            description: "The page stopped responding",
            screenshot: (Data([0, 1, 2, 3]), "image/png")
        )

        XCTAssertTrue(result.reported)
        XCTAssertEqual(result.id, "report-123")
        let request = try XCTUnwrap(IssueReportURLProtocol.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.url?.path.hasSuffix("/api/issue-reports") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertTrue((request.value(forHTTPHeaderField: "Authorization") ?? "").hasPrefix("Bearer "))

        let body = try XCTUnwrap(IssueReportURLProtocol.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["description"] as? String, "The page stopped responding")
        XCTAssertEqual(json["language"] as? String, "en")
        XCTAssertFalse((json["appVersion"] as? String ?? "").isEmpty)
        XCTAssertFalse((json["osVersion"] as? String ?? "").isEmpty)
        XCTAssertFalse((json["deviceModel"] as? String ?? "").isEmpty)
        let screenshot = try XCTUnwrap(json["screenshot"] as? [String: Any])
        XCTAssertEqual(screenshot["contentType"] as? String, "image/png")
        XCTAssertEqual(screenshot["data"] as? String, Data([0, 1, 2, 3]).base64EncodedString())
    }

    func testScreenshotIsOmittedUnlessCallerExplicitlyProvidesIt() async throws {
        IssueReportURLProtocol.respond(status: 200, json: ["reported": true, "id": "without-image"])

        _ = try await IssueReportService.submit(description: "Text only")

        let body = try XCTUnwrap(IssueReportURLProtocol.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["screenshot"])
        XCTAssertEqual(json["language"] as? String, "system")
    }

    func testRateLimitHasItsOwnErrorType() async {
        IssueReportURLProtocol.respond(status: 429, json: ["error": "Too many reports"])

        do {
            _ = try await IssueReportService.submit(description: "Repeated")
            XCTFail("Expected RateLimitedError")
        } catch is IssueReportService.RateLimitedError {
            // Expected.
        } catch {
            XCTFail("Expected RateLimitedError, got \(error)")
        }
    }

    func testServerMessageAndStatusArePreserved() async {
        IssueReportURLProtocol.respond(status: 503, json: ["error": "Maintenance"])

        do {
            _ = try await IssueReportService.submit(description: "Failure")
            XCTFail("Expected ServerError")
        } catch let error as IssueReportService.ServerError {
            XCTAssertEqual(error.status, 503)
            XCTAssertEqual(error.message, "Maintenance")
        } catch {
            XCTFail("Expected ServerError, got \(error)")
        }
    }

    func testUnauthorizedResponseBroadcastsAuthenticationFailure() async {
        IssueReportURLProtocol.respond(status: 401, json: ["error": "Expired"])
        let notification = expectation(forNotification: .studiquoAuthFailed, object: nil)

        do {
            _ = try await IssueReportService.submit(description: "Unauthorized")
            XCTFail("Expected ServerError")
        } catch let error as IssueReportService.ServerError {
            XCTAssertEqual(error.status, 401)
        } catch {
            XCTFail("Expected ServerError, got \(error)")
        }

        await fulfillment(of: [notification], timeout: 1)
    }

    func testMalformedErrorResponseBecomesBadServerResponse() async {
        IssueReportURLProtocol.respond(status: 500, data: Data("not-json".utf8))

        do {
            _ = try await IssueReportService.submit(description: "Failure")
            XCTFail("Expected URLError")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        } catch {
            XCTFail("Expected URLError, got \(error)")
        }
    }
}

private final class IssueReportURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responseStatus = 200
    private static var responseData = Data()
    private(set) static var request: URLRequest?
    private(set) static var body: Data?

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        responseStatus = 200
        responseData = Data()
        request = nil
        body = nil
    }

    static func respond(status: Int, json: [String: Any]) {
        respond(status: status, data: try! JSONSerialization.data(withJSONObject: json))
    }

    static func respond(status: Int, data: Data) {
        lock.lock(); defer { lock.unlock() }
        responseStatus = status
        responseData = data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.request = request
        Self.body = request.httpBody ?? request.httpBodyStream.flatMap(Self.read)
        let status = Self.responseStatus
        let data = Self.responseData
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
