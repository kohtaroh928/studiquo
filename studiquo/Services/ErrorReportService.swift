import Foundation
import UIKit

/// The "エラー情報を自動送信" setting. On unless the person turned it off.
enum ErrorReportSettings {
    static let enabledKey = "autoErrorReportingEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}

/// One problem the app wants the dashboard to know about: what kind, a short
/// title, a stable `signature` (two reports with the same kind and signature
/// are the same problem to the server), and a trimmed technical `detail`.
///
/// Nothing here is ever built from note, chat, AI or account content — only
/// error codes, crash call-site addresses and version numbers. The server
/// bounds every field again, but the rule starts here.
struct ErrorReport: Codable, Equatable {
    var kind: String
    var signature: String
    var title: String
    var detail: String
    var count: Int
    /// Milliseconds since 1970, to match the server's `occurredAt`.
    var occurredAt: Int64
    var appVersion: String?
    var osVersion: String?
    var deviceModel: String?

    var key: String { "\(kind)\n\(signature)" }
}

/// Reports waiting to be sent, kept on disk (UserDefaults) so a crash report
/// found at launch survives being offline, and so one that is still queued
/// when the app is killed isn't lost.
///
/// It also keeps the volume sane on both ends: the same problem is stored
/// once with a count, only a bounded number of distinct problems are kept,
/// and only a bounded number are accepted per day.
final class ErrorReportQueue: @unchecked Sendable {
    static let maxEntries = 50
    static let dailyLimit = 30

    private let defaults: UserDefaults
    private let storageKey: String
    private let dayKey: String
    private let now: () -> Date
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard,
         storageKey: String = "pendingErrorReports",
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.dayKey = storageKey + ".daily"
        self.now = now
    }

    private func load() -> [ErrorReport] {
        guard let data = defaults.data(forKey: storageKey),
              let reports = try? JSONDecoder().decode([ErrorReport].self, from: data) else { return [] }
        return reports
    }

    private func save(_ reports: [ErrorReport]) {
        if reports.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else if let data = try? JSONEncoder().encode(reports) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private var today: String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: now())
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    /// Returns false when the report was dropped (over the daily budget, or
    /// the queue is full of other problems).
    @discardableResult
    func enqueue(_ report: ErrorReport) -> Bool {
        lock.lock(); defer { lock.unlock() }

        var budget = (defaults.dictionary(forKey: dayKey) as? [String: Int]) ?? [:]
        let used = budget[today] ?? 0
        guard used < Self.dailyLimit else { return false }

        var reports = load()
        if let index = reports.firstIndex(where: { $0.key == report.key }) {
            reports[index].count += max(1, report.count)
            reports[index].occurredAt = max(reports[index].occurredAt, report.occurredAt)
        } else {
            guard reports.count < Self.maxEntries else { return false }
            var stored = report
            stored.count = max(1, report.count)
            reports.append(stored)
        }
        save(reports)
        // Only today's count is kept; older days are of no use.
        defaults.set([today: used + 1], forKey: dayKey)
        return true
    }

    func pending() -> [ErrorReport] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    /// Removes what was sent. A problem that happened again while the request
    /// was in flight keeps its newer occurrences.
    func acknowledge(_ sent: [ErrorReport]) {
        lock.lock(); defer { lock.unlock() }
        var reports = load()
        for item in sent {
            guard let index = reports.firstIndex(where: { $0.key == item.key }) else { continue }
            reports[index].count -= item.count
            if reports[index].count <= 0 { reports.remove(at: index) }
        }
        save(reports)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
    }
}

/// Sends queued problem reports to the studiquo server (see
/// mcp-server/src/app-errors.js), where they show on the admin dashboard and
/// — the first time a problem appears — in Slack.
///
/// Silent by design, like `UsageEventService`: a failed send leaves the
/// reports queued for the next time the app becomes active, and nothing here
/// is ever shown to the person using the app.
enum ErrorReportService {
    static let queue = ErrorReportQueue()

    private static var endpoint: URL {
        MCPCloudCredentials.configuredEndpoint() ?? URL(string: WorkerAIProvider.defaultEndpoint)!
    }

    /// The server accepts up to 20 problems per request.
    static let batchSize = 20

    private struct Body: Encodable {
        let appVersion: String
        let osVersion: String
        let deviceModel: String
        let errors: [ErrorReport]
    }

    static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    /// Queues one problem. Does nothing when the person has turned the
    /// setting off.
    static func record(kind: String, signature: String, title: String, detail: String = "",
                       count: Int = 1, occurredAt: Date = Date(),
                       appVersion: String? = nil, osVersion: String? = nil, deviceModel: String? = nil) {
        guard ErrorReportSettings.isEnabled else { return }
        queue.enqueue(ErrorReport(
            kind: kind,
            signature: signature,
            title: title,
            detail: detail,
            count: count,
            occurredAt: Int64(occurredAt.timeIntervalSince1970 * 1000),
            appVersion: appVersion,
            osVersion: osVersion,
            deviceModel: deviceModel
        ))
    }

    /// A failure the app already knows how to describe: only the error's
    /// domain and code, never its message (which can include file paths or
    /// names).
    static func recordFailure(area: String, error: Error) {
        let nsError = error as NSError
        record(
            kind: "error",
            signature: "\(area)|\(nsError.domain)|\(nsError.code)",
            title: "\(area): \(nsError.domain) (\(nsError.code))",
            detail: "area: \(area)\ndomain: \(nsError.domain)\ncode: \(nsError.code)"
        )
    }

    private static let flushLock = NSLock()
    private static var isFlushing = false

    /// Sends what is queued. Safe to call often; only one send runs at a time.
    static func flush() async {
        // Anything queued before the setting was turned off is discarded
        // rather than sent later.
        guard ErrorReportSettings.isEnabled else {
            queue.clear()
            return
        }
        flushLock.lock()
        if isFlushing { flushLock.unlock(); return }
        isFlushing = true
        flushLock.unlock()
        defer { flushLock.lock(); isFlushing = false; flushLock.unlock() }

        while ErrorReportSettings.isEnabled {
            let batch = Array(queue.pending().prefix(batchSize))
            guard !batch.isEmpty else { return }
            switch await send(batch) {
            case .delivered, .rejected:
                // A report the server refuses outright (400) would be
                // refused again forever; dropping it keeps the queue moving.
                queue.acknowledge(batch)
            case .retryLater:
                return
            }
        }
    }

    private enum Outcome { case delivered, rejected, retryLater }

    private static func send(_ batch: [ErrorReport]) async -> Outcome {
        var request = URLRequest(url: endpoint.appending(path: "api/app-errors"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(MCPCloudCredentials.loadOrCreateToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let osVersion = await UIDevice.current.systemVersion
        let body = Body(appVersion: appVersion, osVersion: osVersion, deviceModel: deviceModel, errors: batch)
        guard let data = try? JSONEncoder().encode(body) else { return .rejected }
        request.httpBody = data

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return .retryLater }
        switch http.statusCode {
        case 200..<300: return .delivered
        case 400, 413: return .rejected
        // 401 (not signed in yet / stale token), 429, 5xx: keep and retry.
        default: return .retryLater
        }
    }
}
