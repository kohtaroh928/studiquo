import Foundation

/// What the server says about itself when it is paused or the app is too old.
///
/// The Worker answers `503` with `code: "maintenance"` while the operator holds the
/// whole service (MAINTENANCE_MODE), `503` with `code: "feature_disabled"` and a
/// `feature` name while one part is stopped (DISABLED_FEATURES), and `426` with
/// `code: "app_update_required"` for a build below MIN_APP_BUILD. Without this the
/// student sees an unexplained failure. See `docs/RUNBOOK.md` RB-13.
enum ServerNotice: Equatable {
    case maintenance(retryAfter: TimeInterval)
    case updateRequired
    case featureDisabled(feature: String, retryAfter: TimeInterval)

    /// What the server asks for when it says nothing (the Worker sends 300).
    static let defaultRetryAfter: TimeInterval = 300

    private struct Body: Decodable {
        var code: String?
        var feature: String?
    }

    /// nil for any other response, including a 503 with some other `code`
    /// (the server being busy is not an announcement).
    static func parse(statusCode: Int, retryAfterHeader: String?, body: Data?) -> ServerNotice? {
        let code = body.flatMap { try? JSONDecoder().decode(Body.self, from: $0) }
        let retryAfter = retryAfterHeader
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            .flatMap { $0 > 0 ? $0 : nil } ?? defaultRetryAfter
        switch (statusCode, code?.code) {
        case (503, "maintenance"):
            return .maintenance(retryAfter: retryAfter)
        case (503, "feature_disabled"):
            return .featureDisabled(feature: code?.feature ?? "", retryAfter: retryAfter)
        case (426, "app_update_required"):
            return .updateRequired
        default:
            return nil
        }
    }

    /// A stream's body is not read, so a 426 is recognised by its status alone
    /// (only the minimum-build check sends it).
    static func parseStatusOnly(statusCode: Int) -> ServerNotice? {
        statusCode == 426 ? .updateRequired : nil
    }

    /// Whole sentences, not a name pasted into a template: word order differs by
    /// language. A feature this build does not know still gets a sentence.
    static func featureMessage(_ feature: String) -> String {
        switch feature {
        case "ai": L("AI機能は一時的に停止しています。しばらくしてからもう一度お試しください。")
        case "chat": L("フレンドとチャットは一時的に停止しています。しばらくしてからもう一度お試しください。")
        case "collab": L("共同編集は一時的に停止しています。しばらくしてからもう一度お試しください。")
        case "mcp": L("MCP連携は一時的に停止しています。しばらくしてからもう一度お試しください。")
        case "signin": L("ログインは一時的に停止しています。しばらくしてからもう一度お試しください。")
        case "email": L("メールの送信は一時的に停止しています。しばらくしてからもう一度お試しください。")
        case "push": L("通知は一時的に停止しています。しばらくしてからもう一度お試しください。")
        default: L("一部の機能は一時的に停止しています。しばらくしてからもう一度お試しください。")
        }
    }

    /// True for a feature name this build has its own sentence for.
    static func isKnownFeature(_ feature: String) -> Bool {
        ["ai", "chat", "collab", "mcp", "signin", "email", "push"].contains(feature)
    }

    var message: String {
        switch self {
        case .maintenance:
            L("ただいまメンテナンス中です。しばらくしてからもう一度お試しください。端末内のノートはそのまま使えます。")
        case .updateRequired:
            L("このバージョンのStudiquoはご利用いただけなくなりました。App Storeで最新版に更新してください。")
        case .featureDisabled(let feature, _):
            Self.featureMessage(feature)
        }
    }

    var retryAfter: TimeInterval? {
        switch self {
        case .maintenance(let seconds), .featureDisabled(_, let seconds): seconds
        case .updateRequired: nil
        }
    }
}

/// Holds the notice the banner shows.
///
/// A maintenance or feature notice goes away by itself after the time the server
/// asked for; a maintenance notice also as soon as the same server answers a
/// request normally. An update notice stays until the student puts it away, and
/// returns with the next call: the build will not work until it is updated.
@MainActor
final class ServerNoticeCenter: ObservableObject {
    static let shared = ServerNoticeCenter()

    /// The App Store page of the app, for the update button. Left nil until the app
    /// has an App Store ID: the banner then shows the words without a button.
    static var updateURL: URL? { nil }

    @Published private(set) var notice: ServerNotice?
    private var host: String?
    private var expiry: Task<Void, Never>?
    private let sleep: @Sendable (TimeInterval) async -> Void

    init(sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(for: .seconds(seconds))
    }) {
        self.sleep = sleep
    }

    func report(_ new: ServerNotice, host: String?) {
        // An update notice is not replaced by a passing one.
        if notice == .updateRequired, new != .updateRequired { return }
        notice = new
        self.host = host
        expiry?.cancel()
        guard let seconds = new.retryAfter else { return }
        let sleep = self.sleep
        expiry = Task { [weak self] in
            await sleep(seconds)
            guard !Task.isCancelled else { return }
            self?.expire(ifStill: new)
        }
    }

    /// A normal answer from `host`: if the whole service was paused, it is over.
    /// A stopped feature is not cleared this way: another route answering says
    /// nothing about that one, so it ends with the time the server asked for.
    func recovered(host: String?) {
        guard case .maintenance = notice, host == self.host else { return }
        clear()
    }

    /// "Later" / "Close". An update notice can be put away too, but comes back with
    /// the next 426, which is every call this build makes.
    func dismiss() {
        clear()
    }

    private func expire(ifStill expected: ServerNotice) {
        if notice == expected { clear() }
    }

    private func clear() {
        notice = nil
        host = nil
        expiry?.cancel()
        expiry = nil
    }
}

extension URLSession {
    /// `data(for:)` that also tells the student when the server is paused or the app
    /// is too old. Use it for calls to the Studiquo Worker, not for other hosts.
    func dataNoticing(for request: URLRequest) async throws -> (Data, URLResponse) {
        let result = try await data(for: request)
        ServerNoticeObserver.observe(response: result.1, body: result.0, host: request.url?.host)
        return result
    }

    /// `bytes(for:)` with the same, for streams. The body is not read, so only the
    /// update notice (a 426) is recognised.
    func bytesNoticing(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        let result = try await bytes(for: request)
        ServerNoticeObserver.observe(response: result.1, body: nil, host: request.url?.host)
        return result
    }
}

enum ServerNoticeObserver {
    static func observe(response: URLResponse, body: Data?, host: String?) {
        guard let http = response as? HTTPURLResponse else { return }
        let notice = body == nil
            ? ServerNotice.parseStatusOnly(statusCode: http.statusCode)
            : ServerNotice.parse(statusCode: http.statusCode, retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"), body: body)
        let succeeded = (200..<300).contains(http.statusCode)
        guard notice != nil || succeeded else { return }
        Task { @MainActor in
            if let notice { ServerNoticeCenter.shared.report(notice, host: host) }
            else { ServerNoticeCenter.shared.recovered(host: host) }
        }
    }
}
