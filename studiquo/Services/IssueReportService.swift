import Foundation
import UIKit

/// Sends a "問題を報告" submission from ReportIssueButton/ReportIssueSheet to
/// the Studiquo server (see mcp-server/src/issue-reports.js), which relays it
/// to Slack immediately and keeps a copy for later. Mirrors the request shape
/// FriendChatService already uses for its own authenticated JSON calls.
enum IssueReportService {
    private static var endpoint: URL {
        MCPCloudCredentials.configuredEndpoint() ?? URL(string: WorkerAIProvider.defaultEndpoint)!
    }

    struct SubmitResult: Codable { let reported: Bool; let id: String }
    struct RateLimitedError: Error {}
    /// Carries the server's own `{"error": "..."}` message through to the
    /// caller instead of collapsing every non-2xx response into the same
    /// generic network error.
    struct ServerError: Error {
        let status: Int
        let message: String
    }
    private struct ErrorPayload: Decodable { let error: String }

    private struct ScreenshotPayload: Encodable {
        let contentType: String
        let data: String
    }

    private struct SubmitBody: Encodable {
        let description: String
        let appVersion: String
        let osVersion: String
        let deviceModel: String
        let language: String
        var screenshot: ScreenshotPayload?
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    /// Mirrors NotificationLocale's own reasoning in ContentView.swift: the
    /// user's in-app language choice, not the device's raw locale, since the
    /// bundle declares no Japanese localization for the latter to reflect.
    private static var language: String {
        let stored = UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        return stored.isEmpty ? "system" : stored
    }

    /// `screenshot` is only ever what the caller explicitly opted to attach
    /// (see ReportIssueSheet's toggle) — this function never captures
    /// anything on its own.
    static func submit(description: String, screenshot: (data: Data, contentType: String)? = nil) async throws -> SubmitResult {
        var request = URLRequest(url: endpoint.appending(path: "api/issue-reports"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(MCPCloudCredentials.loadOrCreateToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = SubmitBody(
            description: description,
            appVersion: appVersion,
            osVersion: UIDevice.current.systemVersion,
            deviceModel: deviceModel,
            language: language,
            screenshot: screenshot.map { ScreenshotPayload(contentType: $0.contentType, data: $0.data.base64EncodedString()) }
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard 200..<300 ~= http.statusCode else {
            if http.statusCode == 429 { throw RateLimitedError() }
            guard let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data) else {
                throw URLError(.badServerResponse)
            }
            if http.statusCode == 401 { NotificationCenter.default.post(name: .studiquoAuthFailed, object: nil) }
            throw ServerError(status: http.statusCode, message: payload.error)
        }
        return try JSONDecoder().decode(SubmitResult.self, from: data)
    }
}
