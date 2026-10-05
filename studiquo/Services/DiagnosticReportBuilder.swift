import Foundation

/// Turns what MetricKit hands the app after a crash or hang into an
/// `ErrorReport`. Kept free of MetricKit types so it can be tested with plain
/// values (see `DiagnosticReportBuilderTests`).
///
/// A diagnostic is addresses and codes, not content: exception type, signal,
/// the system's termination reason, and the call stack as
/// "binary + offset" pairs. No function names (the build isn't symbolicated
/// on the device), no memory contents, nothing from the person's notes.
enum DiagnosticReportBuilder {
    struct Frame: Equatable {
        let binaryName: String
        let binaryUUID: String
        let offset: Int
    }

    /// The thread that matters, innermost call first. MetricKit's call stack
    /// tree is a single root (the outermost call) whose `subFrames` lead down
    /// to the call that was running; where it branches, the busiest branch
    /// is followed.
    static func frames(fromCallStackTree json: Data?) -> [Frame] {
        guard let json,
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]] else { return [] }
        let attributed = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        guard var node = (attributed?["callStackRootFrames"] as? [[String: Any]])?.first else { return [] }

        var outermostFirst: [Frame] = []
        while true {
            outermostFirst.append(Frame(
                binaryName: node["binaryName"] as? String ?? "?",
                binaryUUID: node["binaryUUID"] as? String ?? "",
                offset: (node["offsetIntoBinaryTextSegment"] as? NSNumber)?.intValue ?? 0
            ))
            let children = node["subFrames"] as? [[String: Any]] ?? []
            guard let next = children.max(by: { sampleCount($0) < sampleCount($1) }) else { break }
            node = next
        }
        return outermostFirst.reversed()
    }

    private static func sampleCount(_ frame: [String: Any]) -> Int {
        (frame["sampleCount"] as? NSNumber)?.intValue ?? 0
    }

    static let machExceptionNames: [Int: String] = [
        1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION",
        5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 7: "EXC_SYSCALL", 8: "EXC_MACH_SYSCALL",
        9: "EXC_RPC_ALERT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD", 13: "EXC_CORPSE_NOTIFY",
    ]

    static let signalNames: [Int: String] = [
        4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 13: "SIGPIPE",
    ]

    /// How the report is identified. Offsets are per build, so the same bug
    /// in a later build is a new row — that is the cost of not symbolicating
    /// on the device — but within one build every occurrence lands on the same
    /// row however many people hit it.
    private static func appFrames(_ frames: [Frame], appBinary: String) -> [Frame] {
        let own = frames.filter { $0.binaryName == appBinary }
        return Array((own.isEmpty ? frames : own).prefix(3))
    }

    private static func frameText(_ frame: Frame) -> String {
        "\(frame.binaryName)+0x\(String(frame.offset, radix: 16))"
    }

    private static func detail(header: [String], frames: [Frame]) -> String {
        let lines = header + ["frames (innermost first):"] + frames.prefix(25).map {
            "\(frameText($0)) \($0.binaryUUID)"
        }
        return lines.joined(separator: "\n")
    }

    static func crash(
        exceptionType: Int?, signal: Int?, terminationReason: String?, callStackTree: Data?,
        appBinary: String = "studiquo", appVersion: String?, osVersion: String?, occurredAt: Date = Date()
    ) -> ErrorReport {
        let frames = frames(fromCallStackTree: callStackTree)
        let top = appFrames(frames, appBinary: appBinary)
        let exception = exceptionType.map { machExceptionNames[$0] ?? "EXC_\($0)" } ?? "unknown exception"
        let signalName = signal.map { signalNames[$0] ?? "signal \($0)" }
        let label = [exception, signalName.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        let place = top.first.map { " — \(frameText($0))" } ?? ""
        let signature = (["crash", exception, signalName ?? "", terminationReason ?? ""]
            + top.map { "\($0.binaryUUID):\($0.offset)" }).joined(separator: "|")
        var header = ["exception: \(exception)"]
        if let signalName { header.append("signal: \(signalName)") }
        if let terminationReason, !terminationReason.isEmpty { header.append("termination: \(terminationReason)") }
        return ErrorReport(
            kind: "crash", signature: signature, title: label + place,
            detail: detail(header: header, frames: frames), count: 1,
            occurredAt: Int64(occurredAt.timeIntervalSince1970 * 1000),
            appVersion: appVersion, osVersion: osVersion, deviceModel: nil
        )
    }

    /// `kind` is "hang", "cpu" or "disk". The measured amount (how long, how
    /// much) varies every time, so it goes in the detail, not the signature.
    static func resourceIssue(
        kind: String, measurement: String?, callStackTree: Data?,
        appBinary: String = "studiquo", appVersion: String?, osVersion: String?, occurredAt: Date = Date()
    ) -> ErrorReport {
        let frames = frames(fromCallStackTree: callStackTree)
        let top = appFrames(frames, appBinary: appBinary)
        let name = ["hang": "フリーズ", "cpu": "CPU過負荷", "disk": "ディスク書き込み過多"][kind] ?? "エラー"
        let place = top.first.map { " — \(frameText($0))" } ?? ""
        let signature = ([kind] + top.map { "\($0.binaryUUID):\($0.offset)" }).joined(separator: "|")
        return ErrorReport(
            kind: kind, signature: signature, title: name + place,
            detail: detail(header: measurement.map { ["measured: \($0)"] } ?? [], frames: frames), count: 1,
            occurredAt: Int64(occurredAt.timeIntervalSince1970 * 1000),
            appVersion: appVersion, osVersion: osVersion, deviceModel: nil
        )
    }
}
