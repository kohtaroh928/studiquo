import CloudKit
import XCTest
@testable import studiquo

/// The app's side of the automatic error reports (the server and dashboard
/// side is covered by mcp-server/src/admin-inbox.test.js): what gets queued,
/// how it is kept small, how a crash report is built from MetricKit's data,
/// and when it is actually sent.
final class ErrorReportQueueTests: XCTestCase {
    private var defaults: UserDefaults!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ErrorReportQueueTests-\(UUID().uuidString)")
    }

    private func makeQueue() -> ErrorReportQueue {
        ErrorReportQueue(defaults: defaults, now: { self.now })
    }

    private func report(_ signature: String = "sig", count: Int = 1, at: Int64 = 1_000) -> ErrorReport {
        ErrorReport(kind: "crash", signature: signature, title: "title", detail: "detail", count: count, occurredAt: at)
    }

    func testTheSameProblemIsStoredOnceWithItsCount() {
        let queue = makeQueue()
        queue.enqueue(report(count: 2, at: 1_000))
        queue.enqueue(report(count: 1, at: 5_000))
        let pending = queue.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.count, 3)
        XCTAssertEqual(pending.first?.occurredAt, 5_000, "最後に起きた時刻が残る必要があります。")
    }

    func testDifferentProblemsAreKeptApart() {
        let queue = makeQueue()
        queue.enqueue(report("a"))
        queue.enqueue(report("b"))
        var hang = report("a")
        hang.kind = "hang"
        queue.enqueue(hang)
        XCTAssertEqual(queue.pending().count, 3)
    }

    func testQueuedReportsSurviveRelaunch() {
        makeQueue().enqueue(report("persisted"))
        XCTAssertEqual(makeQueue().pending().map(\.signature), ["persisted"])
    }

    func testOnlyABoundedNumberOfDistinctProblemsAreKept() {
        let queue = makeQueue()
        // Spread across days so the daily budget isn't what stops this.
        for i in 0..<(ErrorReportQueue.maxEntries + 10) {
            now = Date(timeIntervalSince1970: 1_800_000_000 + Double(i / 20) * 86_400)
            queue.enqueue(report("sig-\(i)"))
        }
        XCTAssertEqual(queue.pending().count, ErrorReportQueue.maxEntries)
    }

    func testDailyBudgetStopsAFloodAndResetsTheNextDay() {
        let queue = makeQueue()
        for i in 0..<(ErrorReportQueue.dailyLimit + 5) { queue.enqueue(report("sig-\(i)")) }
        XCTAssertEqual(queue.pending().count, ErrorReportQueue.dailyLimit)
        XCTAssertFalse(queue.enqueue(report("one-more")), "1日の上限を超えた分は受け付けない必要があります。")

        now = now.addingTimeInterval(86_400)
        XCTAssertTrue(queue.enqueue(report("next-day")))
    }

    func testAcknowledgeRemovesWhatWasSentButKeepsNewerOccurrences() {
        let queue = makeQueue()
        queue.enqueue(report("busy", count: 3))
        let sent = queue.pending()
        queue.enqueue(report("busy", count: 2)) // happened again while the request was in flight
        queue.acknowledge(sent)
        XCTAssertEqual(queue.pending().first?.count, 2)

        queue.acknowledge(queue.pending())
        XCTAssertTrue(queue.pending().isEmpty)
    }

    func testClearEmptiesTheQueue() {
        let queue = makeQueue()
        queue.enqueue(report())
        queue.clear()
        XCTAssertTrue(queue.pending().isEmpty)
    }
}

final class DiagnosticReportBuilderTests: XCTestCase {
    /// A call-stack tree shaped like MetricKit's: one root (outermost call),
    /// each frame's `subFrames` leading down to the call that was running.
    private func tree(appOffset: Int = 0x1a2b, side: Bool = false) -> Data {
        let leaf: [String: Any] = ["binaryName": "studiquo", "binaryUUID": "UUID-APP", "offsetIntoBinaryTextSegment": appOffset, "sampleCount": 1]
        let sideBranch: [String: Any] = ["binaryName": "other", "binaryUUID": "UUID-OTHER", "offsetIntoBinaryTextSegment": 9, "sampleCount": 0]
        let middle: [String: Any] = ["binaryName": "SwiftUI", "binaryUUID": "UUID-UI", "offsetIntoBinaryTextSegment": 0x40, "sampleCount": 1,
                                     "subFrames": side ? [sideBranch, leaf] : [leaf]]
        let root: [String: Any] = ["binaryName": "dyld", "binaryUUID": "UUID-DYLD", "offsetIntoBinaryTextSegment": 0x10, "sampleCount": 1, "subFrames": [middle]]
        let json: [String: Any] = ["callStacks": [["threadAttributed": true, "callStackRootFrames": [root]]], "callStackPerThread": false]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testFramesComeOutInnermostFirstFollowingTheBusiestBranch() {
        let frames = DiagnosticReportBuilder.frames(fromCallStackTree: tree(side: true))
        XCTAssertEqual(frames.map(\.binaryName), ["studiquo", "SwiftUI", "dyld"])
        XCTAssertEqual(frames.first?.offset, 0x1a2b)
        XCTAssertEqual(frames.first?.binaryUUID, "UUID-APP")
    }

    func testGarbageOrMissingTreesGiveNoFramesRatherThanCrashing() {
        XCTAssertTrue(DiagnosticReportBuilder.frames(fromCallStackTree: nil).isEmpty)
        XCTAssertTrue(DiagnosticReportBuilder.frames(fromCallStackTree: Data("not json".utf8)).isEmpty)
        XCTAssertTrue(DiagnosticReportBuilder.frames(fromCallStackTree: Data("{}".utf8)).isEmpty)
    }

    func testACrashReportDescribesTheExceptionAndWhereItHappened() {
        let report = DiagnosticReportBuilder.crash(
            exceptionType: 1, signal: 11, terminationReason: nil, callStackTree: tree(),
            appVersion: "1.0 (23)", osVersion: "27.0"
        )
        XCTAssertEqual(report.kind, "crash")
        XCTAssertEqual(report.title, "EXC_BAD_ACCESS (SIGSEGV) — studiquo+0x1a2b")
        XCTAssertTrue(report.detail.contains("studiquo+0x1a2b UUID-APP"), "解読に必要なバイナリ識別子が詳細に含まれる必要があります。")
        XCTAssertEqual(report.appVersion, "1.0 (23)")
        XCTAssertEqual(report.osVersion, "27.0")
    }

    func testTheSameCrashAlwaysHasTheSameSignatureAndADifferentOneDoesNot() {
        func signature(offset: Int = 0x1a2b, signal: Int = 11) -> String {
            DiagnosticReportBuilder.crash(exceptionType: 1, signal: signal, terminationReason: nil,
                                          callStackTree: tree(appOffset: offset), appVersion: "1.0 (1)", osVersion: nil).signature
        }
        XCTAssertEqual(signature(), signature(), "同じクラッシュは同じ行にまとまる必要があります。")
        XCTAssertNotEqual(signature(), signature(offset: 0x9999))
        XCTAssertNotEqual(signature(), signature(signal: 6))
    }

    func testAHangsDurationDoesNotSplitItIntoSeparateProblems() {
        func hang(_ seconds: String) -> ErrorReport {
            DiagnosticReportBuilder.resourceIssue(kind: "hang", measurement: seconds, callStackTree: tree(), appVersion: "1.0 (1)", osVersion: nil)
        }
        XCTAssertEqual(hang("3 s").signature, hang("9 s").signature)
        XCTAssertTrue(hang("3 s").detail.contains("3 s"))
        XCTAssertTrue(hang("3 s").title.hasPrefix("フリーズ"))
    }

    func testUnknownExceptionNumbersStillProduceAUsableReport() {
        let report = DiagnosticReportBuilder.crash(exceptionType: 99, signal: 77, terminationReason: nil, callStackTree: nil, appVersion: nil, osVersion: nil)
        XCTAssertTrue(report.title.contains("EXC_99"))
        XCTAssertTrue(report.title.contains("signal 77"))
    }
}

final class CloudKitErrorReportingTests: XCTestCase {
    func testOrdinaryOfflineAndSignedOutConditionsAreNotReported() {
        for code in [3, 4, 6, 7, 9, 23] {
            XCTAssertFalse(CloudKitErrorReporting.shouldReport(domain: CKErrorDomain, code: code), "CKError \(code) は通常の状態なので報告しない必要があります。")
        }
    }

    func testOtherSyncFailuresAreReported() {
        XCTAssertTrue(CloudKitErrorReporting.shouldReport(domain: CKErrorDomain, code: 11))
        XCTAssertTrue(CloudKitErrorReporting.shouldReport(domain: NSCocoaErrorDomain, code: 3))
    }
}

@MainActor
final class StartupFailureReportingTests: XCTestCase {
    func testALoaderFailureIsHandedToTheFailureCallback() async {
        struct Boom: Error {}
        let reported = expectation(description: "Failure reported")
        let loader = StartupStoreLoader<Int>(timeout: 5, openStore: { throw Boom() }, onFailure: { _ in reported.fulfill() })
        loader.start()
        await fulfillment(of: [reported], timeout: 2)
        guard case .failed = loader.state else { return XCTFail("Should have failed") }
    }
}

/// Sending: the real `ErrorReportService` against a stubbed network.
final class ErrorReportServiceTests: XCTestCase {
    private let enabledKey = ErrorReportSettings.enabledKey

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(RecordingErrorReportProtocol.self)
        RecordingErrorReportProtocol.reset()
        UserDefaults.standard.removeObject(forKey: enabledKey)
        ErrorReportService.queue.clear()
        UserDefaults.standard.removeObject(forKey: "pendingErrorReports.daily")
    }

    override func tearDown() {
        URLProtocol.unregisterClass(RecordingErrorReportProtocol.self)
        UserDefaults.standard.removeObject(forKey: enabledKey)
        ErrorReportService.queue.clear()
        UserDefaults.standard.removeObject(forKey: "pendingErrorReports.daily")
        super.tearDown()
    }

    private func record(_ signature: String = "sig") {
        ErrorReportService.record(kind: "crash", signature: signature, title: "title", detail: "detail")
    }

    func testReportingIsOnUnlessTheSettingIsTurnedOff() {
        XCTAssertTrue(ErrorReportSettings.isEnabled, "初期状態では自動送信がオンである必要があります。")
        UserDefaults.standard.set(false, forKey: enabledKey)
        XCTAssertFalse(ErrorReportSettings.isEnabled)
    }

    func testNothingIsQueuedWhenTheSettingIsOff() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        record()
        XCTAssertTrue(ErrorReportService.queue.pending().isEmpty)
    }

    func testFlushPostsTheQueuedReportsWithABearerTokenAndClearsThem() async throws {
        RecordingErrorReportProtocol.respond(status: 200)
        record("a")
        record("b")

        await ErrorReportService.flush()

        let requests = RecordingErrorReportProtocol.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "POST")
        XCTAssertTrue(requests.first?.url?.path.hasSuffix("api/app-errors") == true)
        XCTAssertTrue((requests.first?.value(forHTTPHeaderField: "Authorization") ?? "").hasPrefix("Bearer "))
        let body = try XCTUnwrap(RecordingErrorReportProtocol.recordedBodies().first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((json["errors"] as? [[String: Any]])?.count, 2)
        XCTAssertNotNil(json["appVersion"])
        XCTAssertNotNil(json["deviceModel"])
        XCTAssertTrue(ErrorReportService.queue.pending().isEmpty)
    }

    func testTheRequestCarriesOnlyDiagnosticFields() async throws {
        RecordingErrorReportProtocol.respond(status: 200)
        record()
        await ErrorReportService.flush()

        let body = try XCTUnwrap(RecordingErrorReportProtocol.recordedBodies().first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["appVersion", "osVersion", "deviceModel", "errors"])
        let error = try XCTUnwrap((json["errors"] as? [[String: Any]])?.first)
        XCTAssertTrue(Set(error.keys).isSubset(of: ["kind", "signature", "title", "detail", "count", "occurredAt", "appVersion", "osVersion", "deviceModel"]),
                      "診断情報以外のフィールドが送信されてはいけません: \(error.keys)")
    }

    func testReportsAreKeptForALaterTryWhenTheSendFails() async {
        for status in [401, 429, 500] {
            RecordingErrorReportProtocol.reset()
            ErrorReportService.queue.clear()
            RecordingErrorReportProtocol.respond(status: status)
            record()
            await ErrorReportService.flush()
            XCTAssertEqual(ErrorReportService.queue.pending().count, 1, "\(status) の場合は、次回のために残す必要があります。")
        }
        RecordingErrorReportProtocol.reset()
        ErrorReportService.queue.clear()
        RecordingErrorReportProtocol.failNextRequest()
        record()
        await ErrorReportService.flush()
        XCTAssertEqual(ErrorReportService.queue.pending().count, 1, "通信できない場合も残す必要があります。")
    }

    func testAReportTheServerRefusesIsDroppedSoItCannotBlockTheQueue() async {
        RecordingErrorReportProtocol.respond(status: 400)
        record()
        await ErrorReportService.flush()
        XCTAssertTrue(ErrorReportService.queue.pending().isEmpty)
    }

    func testTurningTheSettingOffDiscardsWhatWasQueuedAndSendsNothing() async {
        record()
        UserDefaults.standard.set(false, forKey: enabledKey)

        await ErrorReportService.flush()

        XCTAssertTrue(RecordingErrorReportProtocol.recordedRequests().isEmpty, "オフにした後は何も送られてはいけません。")
        XCTAssertTrue(ErrorReportService.queue.pending().isEmpty, "オフにする前に溜まっていた分も破棄される必要があります。")
    }

    func testAnEmptyQueueSendsNothing() async {
        await ErrorReportService.flush()
        XCTAssertTrue(RecordingErrorReportProtocol.recordedRequests().isEmpty)
    }

    func testMoreThanOneBatchIsSentInChunksTheServerAccepts() async throws {
        RecordingErrorReportProtocol.respond(status: 200)
        for i in 0..<(ErrorReportService.batchSize + 5) { record("sig-\(i)") }

        await ErrorReportService.flush()

        let bodies = RecordingErrorReportProtocol.recordedBodies()
        XCTAssertEqual(bodies.count, 2)
        let sizes = try bodies.map { body -> Int in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return (json["errors"] as? [Any])?.count ?? 0
        }
        XCTAssertEqual(sizes, [ErrorReportService.batchSize, 5])
        XCTAssertTrue(ErrorReportService.queue.pending().isEmpty)
    }

    func testAFailureIsReportedByItsDomainAndCodeNotItsMessage() throws {
        let error = NSError(domain: "NSCocoaErrorDomain", code: 134060,
                            userInfo: [NSLocalizedDescriptionKey: "/Users/someone/private note.sqlite could not be opened"])
        ErrorReportService.recordFailure(area: "起動時のデータ読み込み", error: error)

        let report = try XCTUnwrap(ErrorReportService.queue.pending().first)
        XCTAssertEqual(report.kind, "error")
        XCTAssertTrue(report.title.contains("NSCocoaErrorDomain"))
        XCTAssertTrue(report.title.contains("134060"))
        XCTAssertFalse(report.title.contains("private note"), "エラーの本文(パスや名前を含みうる)は送ってはいけません。")
        XCTAssertFalse(report.detail.contains("private note"))
        XCTAssertFalse(report.signature.contains("private note"))
    }
}

private final class RecordingErrorReportProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []
    private static var bodies: [Data] = []
    private static var nextStatus = 200
    private static var shouldFailNext = false

    static func reset() {
        lock.lock(); requests = []; bodies = []; nextStatus = 200; shouldFailNext = false; lock.unlock()
    }

    static func respond(status: Int) {
        lock.lock(); nextStatus = status; lock.unlock()
    }

    static func failNextRequest() {
        lock.lock(); shouldFailNext = true; lock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    static func recordedBodies() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return bodies
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "studiquo-mcp.studiquo-mcp-server.workers.dev"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        } ?? Data()

        Self.lock.lock()
        Self.requests.append(request)
        Self.bodies.append(body)
        let shouldFail = Self.shouldFailNext
        let status = Self.nextStatus
        Self.lock.unlock()

        if shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let data = Data("{\"received\":true}".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
