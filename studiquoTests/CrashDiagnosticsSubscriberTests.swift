import MetricKit
import XCTest
@testable import studiquo

final class CrashDiagnosticsSubscriberTests: XCTestCase {
    func testStartRegistersTheSubscriberInstance() {
        let subscriber = CrashDiagnosticsSubscriber()
        var registered: MXMetricManagerSubscriber?

        subscriber.start { registered = $0 }

        XCTAssertTrue((registered as AnyObject?) === subscriber)
    }

    func testCrashFieldsBecomeAnErrorReportWithMetricMetadata() {
        let occurredAt = Date(timeIntervalSince1970: 1_800_000_000)

        let report = CrashDiagnosticsSubscriber.crashReport(
            exceptionType: 1,
            signal: 11,
            terminationReason: "Namespace SIGNAL",
            callStackTree: nil,
            applicationVersion: "2.4",
            buildVersion: "81",
            metadataOSVersion: "iPadOS 27.1 (24B55)",
            occurredAt: occurredAt
        )

        XCTAssertEqual(report.kind, "crash")
        XCTAssertTrue(report.title.contains("EXC_BAD_ACCESS"))
        XCTAssertTrue(report.title.contains("SIGSEGV"))
        XCTAssertTrue(report.detail.contains("Namespace SIGNAL"))
        XCTAssertEqual(report.appVersion, "2.4 (81)")
        XCTAssertEqual(report.osVersion, "27.1")
        XCTAssertEqual(report.occurredAt, Int64(occurredAt.timeIntervalSince1970 * 1_000))
    }

    func testResourceDiagnosticPreservesKindAndMeasurement() {
        let report = CrashDiagnosticsSubscriber.resourceReport(
            kind: "hang",
            measurement: "12 s",
            callStackTree: nil,
            applicationVersion: "1.0",
            buildVersion: "3",
            metadataOSVersion: "iOS 26.5 (23F77)",
            occurredAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(report.kind, "hang")
        XCTAssertEqual(report.title, "フリーズ")
        XCTAssertTrue(report.detail.contains("measured: 12 s"))
        XCTAssertEqual(report.appVersion, "1.0 (3)")
        XCTAssertEqual(report.osVersion, "26.5")
    }

    func testRecordQueuesEveryConvertedReportInOrder() {
        let first = ErrorReport(kind: "crash", signature: "1", title: "one", detail: "", count: 1, occurredAt: 1)
        let second = ErrorReport(kind: "hang", signature: "2", title: "two", detail: "", count: 1, occurredAt: 2)
        var recorded: [ErrorReport] = []

        CrashDiagnosticsSubscriber.record([first, second]) { recorded.append($0) }

        XCTAssertEqual(recorded, [first, second])
    }

    func testOSVersionParsingRejectsTextWithoutAVersion() {
        XCTAssertEqual(CrashDiagnosticsSubscriber.parsedOSVersion("iPadOS 27.0.1 (24A123)"), "27.0.1")
        XCTAssertNil(CrashDiagnosticsSubscriber.parsedOSVersion("unknown"))
    }
}
