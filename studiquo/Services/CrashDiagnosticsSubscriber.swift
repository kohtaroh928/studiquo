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
        start { MXMetricManager.shared.add($0) }
    }

    func start(register: (MXMetricManagerSubscriber) -> Void) {
        register(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var reports: [ErrorReport] = []
        for payload in payloads {
            let end = payload.timeStampEnd
            for crash in payload.crashDiagnostics ?? [] {
                reports.append(Self.crashReport(
                    exceptionType: crash.exceptionType?.intValue,
                    signal: crash.signal?.intValue,
                    terminationReason: crash.terminationReason,
                    callStackTree: crash.callStackTree.jsonRepresentation(),
                    applicationVersion: crash.applicationVersion,
                    buildVersion: crash.metaData.applicationBuildVersion,
                    metadataOSVersion: crash.metaData.osVersion,
                    occurredAt: end
                ))
            }
            for hang in payload.hangDiagnostics ?? [] {
                reports.append(Self.resourceReport(
                    kind: "hang",
                    measurement: "\(Int(hang.hangDuration.converted(to: .seconds).value)) s",
                    callStackTree: hang.callStackTree.jsonRepresentation(),
                    applicationVersion: hang.applicationVersion,
                    buildVersion: hang.metaData.applicationBuildVersion,
                    metadataOSVersion: hang.metaData.osVersion,
                    occurredAt: end
                ))
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                reports.append(Self.resourceReport(
                    kind: "cpu",
                    measurement: "\(Int(cpu.totalCPUTime.converted(to: .seconds).value)) s CPU",
                    callStackTree: cpu.callStackTree.jsonRepresentation(),
                    applicationVersion: cpu.applicationVersion,
                    buildVersion: cpu.metaData.applicationBuildVersion,
                    metadataOSVersion: cpu.metaData.osVersion,
                    occurredAt: end
                ))
            }
            for disk in payload.diskWriteExceptionDiagnostics ?? [] {
                reports.append(Self.resourceReport(
                    kind: "disk",
                    measurement: "\(Int(disk.totalWritesCaused.converted(to: .megabytes).value)) MB",
                    callStackTree: disk.callStackTree.jsonRepresentation(),
                    applicationVersion: disk.applicationVersion,
                    buildVersion: disk.metaData.applicationBuildVersion,
                    metadataOSVersion: disk.metaData.osVersion,
                    occurredAt: end
                ))
            }
        }
        Self.record(reports, using: report)
        Task { await ErrorReportService.flush() }
    }

    static func crashReport(
        exceptionType: Int?,
        signal: Int?,
        terminationReason: String?,
        callStackTree: Data?,
        applicationVersion: String,
        buildVersion: String,
        metadataOSVersion: String,
        occurredAt: Date
    ) -> ErrorReport {
        DiagnosticReportBuilder.crash(
            exceptionType: exceptionType,
            signal: signal,
            terminationReason: terminationReason,
            callStackTree: callStackTree,
            appVersion: "\(applicationVersion) (\(buildVersion))",
            osVersion: parsedOSVersion(metadataOSVersion),
            occurredAt: occurredAt
        )
    }

    static func resourceReport(
        kind: String,
        measurement: String,
        callStackTree: Data?,
        applicationVersion: String,
        buildVersion: String,
        metadataOSVersion: String,
        occurredAt: Date
    ) -> ErrorReport {
        DiagnosticReportBuilder.resourceIssue(
            kind: kind,
            measurement: measurement,
            callStackTree: callStackTree,
            appVersion: "\(applicationVersion) (\(buildVersion))",
            osVersion: parsedOSVersion(metadataOSVersion),
            occurredAt: occurredAt
        )
    }

    static func record(_ reports: [ErrorReport], using recorder: (ErrorReport) -> Void) {
        reports.forEach(recorder)
    }

    static func parsedOSVersion(_ metadataOSVersion: String) -> String? {
        metadataOSVersion
            .range(of: #"\d+(\.\d+)*"#, options: .regularExpression)
            .map { String(metadataOSVersion[$0]) }
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
        parsedOSVersion(diagnostic.metaData.osVersion)
    }
}
