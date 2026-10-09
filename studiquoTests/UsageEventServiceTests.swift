import XCTest
@testable import studiquo

/// Coverage for `UsageEventService.ping(session: testSession)` — the client-side half of the
/// DAU/MAU/retention dashboard (see mcp-server/src/admin.js's
/// handleUsageEvent, which the server side already had tests for). The
/// dashboard's numbers are only ever as good as this call actually firing
/// with a real bearer token, so that's what these tests check.
final class UsageEventServiceTests: XCTestCase {
    private var testSession: URLSession!
    private var previousEndpoint: String?
    override func setUp() {
        super.setUp()
        previousEndpoint = UserDefaults.standard.string(forKey: "mcpCloudEndpoint")
        UserDefaults.standard.set(WorkerAIProvider.defaultEndpoint, forKey: "mcpCloudEndpoint")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingUsageEventProtocol.self]
        testSession = URLSession(configuration: configuration)
        RecordingUsageEventProtocol.reset()
    }

    override func tearDown() {
        testSession.invalidateAndCancel()
        testSession = nil
        if let previousEndpoint {
            UserDefaults.standard.set(previousEndpoint, forKey: "mcpCloudEndpoint")
        } else {
            UserDefaults.standard.removeObject(forKey: "mcpCloudEndpoint")
        }
        super.tearDown()
    }

    func testPingPostsToTheUsageEventsEndpointWithABearerToken() async {
        RecordingUsageEventProtocol.respond(status: 200, body: ["recorded": true])

        await UsageEventService.ping(session: testSession)

        let requests = RecordingUsageEventProtocol.recordedRequests()
        XCTAssertEqual(requests.count, 1, "1回のpingで、リクエストがちょうど1件送られる必要があります。")
        XCTAssertEqual(requests.first?.httpMethod, "POST")
        XCTAssertTrue(requests.first?.url?.path.hasSuffix("api/usage-events") == true)
        let authorization = requests.first?.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(authorization.hasPrefix("Bearer "), "認証トークンがBearerヘッダーで送られる必要があります。")
        XCTAssertGreaterThan(authorization.count, "Bearer ".count, "トークン自体が空であってはいけません。")
    }

    func testPingDoesNotThrowOrHangWhenTheServerRejectsTheToken() async {
        RecordingUsageEventProtocol.respond(status: 401, body: ["error": "Reconnect from Studiquo to get a new token."])

        // ping() returns Void and swallows errors by design — this just
        // confirms a 401 doesn't crash or hang the caller.
        await UsageEventService.ping(session: testSession)

        XCTAssertEqual(RecordingUsageEventProtocol.recordedRequests().count, 1)
    }

    func testPingDoesNotThrowOrHangWhenTheNetworkFailsEntirely() async {
        RecordingUsageEventProtocol.failNextRequest()

        await UsageEventService.ping(session: testSession)
        // No assertion beyond "this returned at all" — a hang or crash here
        // would fail the test via timeout, same as the network-failure
        // coverage FriendChatService's own tests rely on.
    }
}

/// Intercepts every request to studiquo's worker host and records it,
/// rather than actually reaching the network — same host-matching approach
/// as AuthenticationStoreTests' own stub, but recording what was sent
/// (method/path/headers) instead of only controlling what comes back.
private final class RecordingUsageEventProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []
    private static var nextResponse: (status: Int, body: [String: Any])?
    private static var shouldFailNext = false

    static func reset() {
        lock.lock(); requests = []; nextResponse = nil; shouldFailNext = false; lock.unlock()
    }

    static func respond(status: Int, body: [String: Any]) {
        lock.lock(); nextResponse = (status, body); lock.unlock()
    }

    static func failNextRequest() {
        lock.lock(); shouldFailNext = true; lock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true // Dedicated test session must never reach the network.
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTAssertEqual(request.url?.host, "studiquo-mcp.studiquo-mcp-server.workers.dev", "Unexpected test request host")
        Self.lock.lock()
        Self.requests.append(request)
        let shouldFail = Self.shouldFailNext
        let match = Self.nextResponse
        Self.lock.unlock()

        if shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let (status, body) = match ?? (200, ["recorded": true])
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
