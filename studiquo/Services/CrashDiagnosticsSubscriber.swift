import Foundation
import MetricKit

/// Receives the crash, hang and resource-exception reports iOS collects about
/// this app (MetricKit delivers them shortly after launch, including for a
/// crash that ended the previous run) and queues them for the dashboard.
///
/// Registered once at launch whether or not reporting is on: what is
/// delivered is dropped by `ErrorReportService.record` when the person has
/// turned "エラー情報を自動送信" off.
final class CrashDiagnosticsSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashDiagnosticsSubscriber()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let end = payload.timeStampEnd
            for crash in payload.crashDiagnostics ?? [] {
                report(DiagnosticReportBuilder.crash(
                    exceptionType: crash.exceptionType?.intValue,
                    signal: crash.signal?.intValue,
                    terminationReason: crash.terminationReason,
                    callStackTree: crash.callStackTree.jsonRepresentation(),
                    appVersion: Self.version(of: crash),
                    osVersion: Self.osVersion(of: crash),
                    occurredAt: end
                ))
            }
            for hang in payload.hangDiagnostics ?? [] {
                report(DiagnosticReportBuilder.resourceIssue(
                    kind: "hang",
                    measurement: "\(Int(hang.hangDuration.converted(to: .seconds).value)) s",
                    callStackTree: hang.callStackTree.jsonRepresentation(),
                    appVersion: Self.version(of: hang),
                    osVersion: Self.osVersion(of: hang),
                    occurredAt: end
                ))
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                report(DiagnosticReportBuilder.resourceIssue(
                    kind: "cpu",
                    measurement: "\(Int(cpu.totalCPUTime.converted(to: .seconds).value)) s CPU",
                    callStackTree: cpu.callStackTree.jsonRepresentation(),
                    appVersion: Self.version(of: cpu),
                    osVersion: Self.osVersion(of: cpu),
                    occurredAt: end
                ))
            }
            for disk in payload.diskWriteExceptionDiagnostics ?? [] {
                report(DiagnosticReportBuilder.resourceIssue(
                    kind: "disk",
                    measurement: "\(Int(disk.totalWritesCaused.converted(to: .megabytes).value)) MB",
                    callStackTree: disk.callStackTree.jsonRepresentation(),
                    appVersion: Self.version(of: disk),
                    osVersion: Self.osVersion(of: disk),
                    occurredAt: end
                ))
            }
        }
        Task { await ErrorReportService.flush() }
    }

    private func report(_ report: ErrorReport) {
        ErrorReportService.record(
            kind: report.kind, signature: report.signature, title: report.title, detail: report.detail,
            count: report.count, occurredAt: Date(timeIntervalSince1970: TimeInterval(report.occurredAt) / 1000),
            appVersion: report.appVersion, osVersion: report.osVersion
        )
    }

    /// The build the problem happened on, which can be older than the one
    /// running now: "1.0 (23)".
    private static func version(of diagnostic: MXDiagnostic) -> String {
        "\(diagnostic.applicationVersion) (\(diagnostic.metaData.applicationBuildVersion))"
    }

    /// MetricKit says "iPadOS 27.0 (24A123)"; the dashboard wants "27.0".
    private static func osVersion(of diagnostic: MXDiagnostic) -> String? {
        diagnostic.metaData.osVersion
            .range(of: #"\d+(\.\d+)*"#, options: .regularExpression)
            .map { String(diagnostic.metaData.osVersion[$0]) }
    }
}
