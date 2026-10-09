import Foundation

/// Sends a single "this account used the app" ping to the server (see
/// mcp-server/src/admin.js's handleUsageEvent), which is all the DAU/MAU/
/// retention numbers on the internal /admin dashboard read from. Mirrors the
/// request shape FriendChatService/IssueReportService already use for their
/// own authenticated JSON calls.
///
/// Deliberately silent on failure — a missed ping just means one fewer data
/// point for the dashboard, never something the person using the app should
/// see or be interrupted by.
enum UsageEventService {
    private static var endpoint: URL {
        MCPCloudCredentials.configuredEndpoint() ?? URL(string: WorkerAIProvider.defaultEndpoint)!
    }

    /// Fires the ping and swallows any error — network failures, a 401 from
    /// a stale token, a 429 from the (generous, 20/min) rate limit — none of
    /// it is actionable for the caller, and the next scenePhase transition
    /// to `.active` will just try again.
    static func ping(session: URLSession = .shared) async {
        var request = URLRequest(url: endpoint.appending(path: "api/usage-events"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(MCPCloudCredentials.loadOrCreateToken())", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }
}
