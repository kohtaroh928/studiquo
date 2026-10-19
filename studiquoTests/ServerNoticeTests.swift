import XCTest
@testable import studiquo

final class ServerNoticeParsingTests: XCTestCase {
    private func body(_ json: String) -> Data { Data(json.utf8) }

    func testMaintenanceIsRecognisedWithItsRetryAfter() {
        let notice = ServerNotice.parse(statusCode: 503, retryAfterHeader: "120", body: body(#"{"error":"x","code":"maintenance"}"#))
        XCTAssertEqual(notice, .maintenance(retryAfter: 120))
    }

    func testAMissingOrUnusableRetryAfterFallsBackToFiveMinutes() {
        for header in [nil, "", "soon", "0", "-5"] as [String?] {
            XCTAssertEqual(
                ServerNotice.parse(statusCode: 503, retryAfterHeader: header, body: body(#"{"code":"maintenance"}"#)),
                .maintenance(retryAfter: 300), "\(String(describing: header))"
            )
        }
    }

    func testAStoppedFeatureCarriesItsName() {
        let notice = ServerNotice.parse(statusCode: 503, retryAfterHeader: "300", body: body(#"{"code":"feature_disabled","feature":"chat"}"#))
        XCTAssertEqual(notice, .featureDisabled(feature: "chat", retryAfter: 300))
    }

    func testUpdateRequiredNeedsBothTheStatusAndTheCode() {
        XCTAssertEqual(ServerNotice.parse(statusCode: 426, retryAfterHeader: nil, body: body(#"{"code":"app_update_required"}"#)), .updateRequired)
        XCTAssertNil(ServerNotice.parse(statusCode: 426, retryAfterHeader: nil, body: body(#"{"code":"other"}"#)))
        XCTAssertNil(ServerNotice.parse(statusCode: 200, retryAfterHeader: nil, body: body(#"{"code":"app_update_required"}"#)))
    }

    func testOtherResponsesAreNotAnnouncements() {
        XCTAssertNil(ServerNotice.parse(statusCode: 503, retryAfterHeader: "5", body: body(#"{"error":"busy"}"#)), "a busy server is not a notice")
        XCTAssertNil(ServerNotice.parse(statusCode: 503, retryAfterHeader: nil, body: nil))
        XCTAssertNil(ServerNotice.parse(statusCode: 503, retryAfterHeader: nil, body: Data("<html>".utf8)), "another host's error page is ignored")
        XCTAssertNil(ServerNotice.parse(statusCode: 500, retryAfterHeader: nil, body: body(#"{"code":"maintenance"}"#)))
        XCTAssertNil(ServerNotice.parse(statusCode: 429, retryAfterHeader: "3", body: body(#"{"code":"feature_disabled"}"#)))
    }

    func testAStreamIsRecognisedByStatusAlone() {
        XCTAssertEqual(ServerNotice.parseStatusOnly(statusCode: 426), .updateRequired)
        XCTAssertNil(ServerNotice.parseStatusOnly(statusCode: 503))
        XCTAssertNil(ServerNotice.parseStatusOnly(statusCode: 200))
    }

    /// The words are looked up per language, so this checks structure, not wording.
    func testEveryFeatureTheServerCanStopHasItsOwnSentence() {
        let known = ["ai", "chat", "collab", "mcp", "signin", "email", "push"]
        let messages = known.map { ServerNotice.featureMessage($0) }
        XCTAssertEqual(Set(messages).count, known.count, "each feature says which part is stopped")
        XCTAssertTrue(known.allSatisfy(ServerNotice.isKnownFeature))
        XCTAssertFalse(ServerNotice.isKnownFeature("something-new"))
        let unknown = ServerNotice.featureMessage("something-new")
        XCTAssertFalse(unknown.isEmpty, "a feature this build does not know still gets a sentence")
        XCTAssertFalse(messages.contains(unknown))
        XCTAssertEqual(ServerNotice.featureDisabled(feature: "chat", retryAfter: 1).message, ServerNotice.featureMessage("chat"))
    }

    func testEveryNoticeHasAMessage() {
        for notice in [ServerNotice.maintenance(retryAfter: 1), .updateRequired, .featureDisabled(feature: "ai", retryAfter: 1)] {
            XCTAssertFalse(notice.message.isEmpty)
        }
    }
}

/// Waits (in real time, briefly) until `condition` holds; the center's timers are
/// tasks, and how soon they run is the scheduler's business.
@MainActor
private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor
final class ServerNoticeCenterTests: XCTestCase {
    /// A sleep the test finishes by hand, one timer at a time.
    private final class Clock: @unchecked Sendable {
        var continuations: [CheckedContinuation<Void, Never>] = []
        func sleep(_ seconds: TimeInterval) async {
            await withCheckedContinuation { continuations.append($0) }
        }
        func fire() { continuations.forEach { $0.resume() }; continuations = [] }
        func fire(at index: Int) { continuations[index].resume() }
    }

    func testMaintenanceShowsAndAnAnswerFromTheSameHostClearsIt() {
        let center = ServerNoticeCenter(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        center.report(.maintenance(retryAfter: 300), host: "api.example")
        XCTAssertEqual(center.notice, .maintenance(retryAfter: 300))

        center.recovered(host: "other.example")
        XCTAssertNotNil(center.notice, "another host answering says nothing about this one")
        center.recovered(host: "api.example")
        XCTAssertNil(center.notice)
    }

    func testAStoppedFeatureIsNotClearedByAnotherRouteAnswering() {
        let center = ServerNoticeCenter(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        center.report(.featureDisabled(feature: "chat", retryAfter: 300), host: "api.example")

        center.recovered(host: "api.example") // /api/plan answering says nothing about chat
        XCTAssertEqual(center.notice, .featureDisabled(feature: "chat", retryAfter: 300))
    }

    func testANoticeEndsAfterTheTimeTheServerAskedFor() async {
        let clock = Clock()
        let center = ServerNoticeCenter(sleep: { await clock.sleep($0) })
        center.report(.featureDisabled(feature: "chat", retryAfter: 300), host: "api.example")
        await waitUntil { !clock.continuations.isEmpty }
        XCTAssertNotNil(center.notice)

        clock.fire()
        await waitUntil { center.notice == nil }
        XCTAssertNil(center.notice)
    }

    func testAnUpdateNoticeIsNotReplacedOrClearedByAGoodAnswer_AndComesBackAfterLater() {
        let center = ServerNoticeCenter(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        center.report(.updateRequired, host: "api.example")

        center.report(.maintenance(retryAfter: 300), host: "api.example")
        XCTAssertEqual(center.notice, .updateRequired)
        center.recovered(host: "api.example")
        XCTAssertEqual(center.notice, .updateRequired, "a good answer does not make an old build current")

        center.dismiss() // "Later"
        XCTAssertNil(center.notice)
        center.report(.updateRequired, host: "api.example") // the next call this build makes
        XCTAssertEqual(center.notice, .updateRequired)
    }

    func testAPassingNoticeCanBeDismissed() {
        let center = ServerNoticeCenter(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        center.report(.maintenance(retryAfter: 300), host: "api.example")
        center.dismiss()
        XCTAssertNil(center.notice)
    }

    func testAnOldTimerCannotEndANewerNotice() async {
        let clock = Clock()
        let center = ServerNoticeCenter(sleep: { await clock.sleep($0) })
        center.report(.maintenance(retryAfter: 300), host: "api.example")
        await waitUntil { clock.continuations.count == 1 }
        center.report(.maintenance(retryAfter: 300), host: "api.example") // the same notice again: the clock starts over
        await waitUntil { clock.continuations.count == 2 }

        clock.fire(at: 0) // the first timer runs out; it was cancelled, so it must do nothing
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(center.notice, .maintenance(retryAfter: 300), "the newer report is still inside its own time")

        clock.fire(at: 1)
        await waitUntil { center.notice == nil }
        XCTAssertNil(center.notice)
    }
}

/// `dataNoticing` against a stubbed network: the real call path an app uses.
@MainActor
final class DataNoticingTests: XCTestCase {
    private final class Stub: URLProtocol {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var headers: [String: String] = [:]
        nonisolated(unsafe) static var body = Data()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: Self.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return URLSession(configuration: configuration)
    }

    override func setUp() {
        super.setUp()
        ServerNoticeCenter.shared.dismiss()
    }

    func testAMaintenanceAnswerReachesTheBannerAndAGoodAnswerClearsIt() async throws {
        Stub.status = 503
        Stub.headers = ["Retry-After": "300"]
        Stub.body = Data(#"{"error":"x","code":"maintenance"}"#.utf8)
        let request = URLRequest(url: URL(string: "https://worker-test.example/api/plan")!)

        let (data, response) = try await session().dataNoticing(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503, "the caller still sees the real answer")
        XCTAssertFalse(data.isEmpty)
        await waitUntil { ServerNoticeCenter.shared.notice != nil }
        XCTAssertEqual(ServerNoticeCenter.shared.notice, .maintenance(retryAfter: 300))

        Stub.status = 200
        Stub.headers = [:]
        Stub.body = Data("{}".utf8)
        _ = try await session().dataNoticing(for: request)
        await waitUntil { ServerNoticeCenter.shared.notice == nil }
        XCTAssertNil(ServerNoticeCenter.shared.notice)
    }

    func testAnOrdinaryErrorLeavesNoNotice() async throws {
        Stub.status = 500
        Stub.headers = [:]
        Stub.body = Data(#"{"error":"boom"}"#.utf8)
        _ = try await session().dataNoticing(for: URLRequest(url: URL(string: "https://worker-test.example/api/plan")!))
        try await Task.sleep(for: .milliseconds(100)) // an ordinary error must stay silent
        XCTAssertNil(ServerNoticeCenter.shared.notice)
    }
}
