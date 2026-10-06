import SwiftUI
import WebKit

/// The page that hosts Cloudflare's Turnstile widget. Built as a string so the
/// site key and action go in as JSON string literals (never concatenated into
/// script), and loaded against the server's own origin because Turnstile only
/// renders on a hostname registered for the site key.
enum TurnstilePage {
    static func html(siteKey: String, action: String) -> String {
        """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;height:100%;background:transparent}body{display:flex;align-items:center;justify-content:center}</style>
        <script src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit&onload=studiquoTurnstileReady" async defer></script>
        </head><body><div id="widget"></div>
        <script>
        function post(message) { window.webkit.messageHandlers.turnstile.postMessage(message); }
        function studiquoTurnstileReady() {
          turnstile.render("#widget", {
            sitekey: \(jsonLiteral(siteKey)),
            action: \(jsonLiteral(action)),
            callback: function (token) { post({ token: token }); },
            "error-callback": function (code) { post({ error: String(code) }); return true; },
            "expired-callback": function () { post({ expired: true }); }
          });
        }
        </script></body></html>
        """
    }

    private static func jsonLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        // ["value"] -> "value"; `</` is escaped so the string can't close the script tag.
        return String(array.dropFirst().dropLast()).replacingOccurrences(of: "</", with: "<\\/")
    }
}

/// What the widget reports back. Anything that isn't exactly one of these is
/// ignored, and a token is bounded to Cloudflare's documented 2048 characters.
enum TurnstileMessage: Equatable {
    case token(String)
    case error
    case expired

    static let maximumTokenLength = 2_048

    init?(body: Any) {
        guard let dictionary = body as? [String: Any] else { return nil }
        if let token = dictionary["token"] as? String {
            guard !token.isEmpty, token.count <= Self.maximumTokenLength else { return nil }
            self = .token(token)
        } else if dictionary["expired"] as? Bool == true {
            self = .expired
        } else if dictionary["error"] is String {
            self = .error
        } else {
            return nil
        }
    }
}

struct TurnstileWebView: UIViewRepresentable {
    let siteKey: String
    let action: String
    let baseURL: URL
    let onMessage: (TurnstileMessage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(baseURL: baseURL, onMessage: onMessage) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "turnstile")
        // Nothing here needs to persist: every challenge starts clean.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(TurnstilePage.html(siteKey: siteKey, action: action), baseURL: baseURL)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "turnstile")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let baseURL: URL
        private let onMessage: (TurnstileMessage) -> Void

        init(baseURL: URL, onMessage: @escaping (TurnstileMessage) -> Void) {
            self.baseURL = baseURL
            self.onMessage = onMessage
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // Only the page itself may report a token, never an embedded frame.
            guard message.name == "turnstile", message.frameInfo.isMainFrame,
                  let parsed = TurnstileMessage(body: message.body) else { return }
            onMessage(parsed)
        }

        // The page is the only thing this view ever shows: a link or redirect
        // that would take the main frame anywhere else is refused. Turnstile's
        // own iframes load as subframes and are unaffected.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.targetFrame?.isMainFrame == true else { return .allow }
            let url = navigationAction.request.url
            return url == nil || url?.scheme == "about" || url?.host == baseURL.host ? .allow : .cancel
        }
    }
}

/// Shown over the sign-in flow when the server wants a CAPTCHA solved.
struct CaptchaSheet: View {
    let challenge: CaptchaChallenge
    let onToken: (String) -> Void
    let onCancel: () -> Void

    @State private var failed = false
    @State private var attempt = 0

    private var baseURL: URL {
        MCPCloudCredentials.configuredEndpoint() ?? URL(string: WorkerAIProvider.defaultEndpoint)!
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("ロボットでないことを確認してください")
                    .font(.headline)
                Text("確認が終わると、続きの操作が自動で行われます。")
                    .font(.footnote).foregroundStyle(.secondary)
                TurnstileWebView(siteKey: challenge.siteKey, action: challenge.action, baseURL: baseURL) { message in
                    switch message {
                    case .token(let token): onToken(token)
                    case .error: failed = true
                    case .expired: attempt += 1
                    }
                }
                .id(attempt)
                .frame(height: 100)
                .accessibilityLabel("ロボットでないことの確認")
                if failed {
                    Text("確認を表示できませんでした。通信状況を確認して、もう一度お試しください。")
                        .font(.footnote).foregroundStyle(.red)
                    Button("もう一度表示する") { failed = false; attempt += 1 }
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: 480)
            .navigationTitle("確認")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル", action: onCancel) }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(false)
    }
}
