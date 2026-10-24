import Foundation

/// Which Worker the app may send its sign-in token and study data to.
///
/// The address is a setting (`mcpCloudEndpoint`), which a build for testing
/// points at the staging Worker. In a released build it must not be possible to
/// point it anywhere else: every cloud request carries the account's bearer
/// token, so a changed value would hand the token to whoever runs that address.
/// A released build therefore only ever talks to the production address, and
/// ignores a stored value that says otherwise. Debug builds (run from Xcode)
/// keep the freedom to use staging.
enum WorkerEndpointPolicy {
    static let productionHost = "api.studiquo.app"
    static let stagingHost = "studiquo-mcp-staging.studiquo-mcp-server.workers.dev"
    static let stagingCustomHost = "staging-api.studiquo.app"

    #if DEBUG
    static let allowsCustomHosts = true
    #else
    static let allowsCustomHosts = false
    #endif

    /// The Worker URL to use for a stored setting. `nil` means the value is not
    /// usable (not https, has credentials, no host, or a host a released build
    /// may not talk to).
    static func resolve(_ stored: String?, allowsCustomHosts: Bool = WorkerEndpointPolicy.allowsCustomHosts) -> URL? {
        var raw = (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { raw = WorkerAIProvider.defaultEndpoint }
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        // A bearer token must only ever leave the device for an environment
        // we own. Debug builds may select staging, but never an arbitrary URL.
        guard url.port == nil, url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil else { return nil }
        guard host == productionHost || (allowsCustomHosts && [stagingHost, stagingCustomHost].contains(host)) else { return nil }
        return url
    }
}

/// Build-time settings shared by the app and its extensions. A staging build
/// shares source code with production, but never shares a server identity,
/// credential namespace or persistent store with it.
enum StudiquoRuntimeEnvironment {
    static let productionEndpoint = URL(string: WorkerAIProvider.defaultEndpoint)!
    static let stagingEndpoint = URL(string: "https://studiquo-mcp-staging.studiquo-mcp-server.workers.dev")!

    static let name = (Bundle.main.object(forInfoDictionaryKey: "StudiquoEnvironment") as? String)?.lowercased() ?? "production"
    static let isStaging = name == "staging"

    static let endpoint: URL = {
        let configured = Bundle.main.object(forInfoDictionaryKey: "StudiquoWorkerEndpoint") as? String
        let fallback = isStaging ? stagingEndpoint : productionEndpoint
        guard let resolved = WorkerEndpointPolicy.resolve(configured, allowsCustomHosts: true) else { return fallback }
        // Do not let an incorrectly generated staging app silently point at production.
        if isStaging {
            return [WorkerEndpointPolicy.stagingHost, WorkerEndpointPolicy.stagingCustomHost].contains(resolved.host?.lowercased() ?? "") ? resolved : stagingEndpoint
        }
        return resolved.host?.lowercased() == WorkerEndpointPolicy.productionHost ? resolved : productionEndpoint
    }()

    static let cloudKitContainer = (Bundle.main.object(forInfoDictionaryKey: "StudiquoCloudKitContainer") as? String)
        ?? "iCloud.com.yabuko.studiquo"
    static let appGroup = (Bundle.main.object(forInfoDictionaryKey: "StudiquoAppGroup") as? String)
        ?? "group.com.yabuko.studiquo.share"
    static let revenueCatPublicAPIKey = Bundle.main.object(forInfoDictionaryKey: "StudiquoRevenueCatPublicAPIKey") as? String

    static func namespaced(_ value: String) -> String {
        isStaging ? "\(value).staging" : value
    }
}

/// Captures the effective endpoint before opening the persistent store.
enum LaunchStoreEnvironment {
    /// The target's build settings, not a mutable preference, choose the
    /// environment. Every request in one run uses this same value.
    static let endpoint: URL? = StudiquoRuntimeEnvironment.endpoint

    static var isStagingEnvironment: Bool { StudiquoRuntimeEnvironment.isStaging }

    /// Keychain and UserDefaults records that hold server credentials must not
    /// cross from the production Worker to the staging Worker.
    static func namespaced(_ value: String) -> String {
        StudiquoRuntimeEnvironment.namespaced(value)
    }

    static func isProduction(_ endpoint: URL) -> Bool {
        endpoint.scheme?.lowercased() == "https" &&
        endpoint.host?.lowercased() == WorkerEndpointPolicy.productionHost && endpoint.port == nil &&
        (endpoint.path.isEmpty || endpoint.path == "/") && endpoint.query == nil && endpoint.fragment == nil
    }

    static func isStaging(_ endpoint: URL) -> Bool {
        endpoint.scheme?.lowercased() == "https" &&
        [WorkerEndpointPolicy.stagingHost, WorkerEndpointPolicy.stagingCustomHost].contains(endpoint.host?.lowercased() ?? "") &&
        endpoint.port == nil && (endpoint.path.isEmpty || endpoint.path == "/") &&
        endpoint.query == nil && endpoint.fragment == nil
    }

    static let ragLock = EndpointChangeLock(launch: endpoint)
}

/// Once a changed or invalid endpoint is observed, RAG stays stopped until relaunch.
final class EndpointChangeLock {
    private let launch: URL?
    private let lock = NSLock()
    private var changed = false

    init(launch: URL?) { self.launch = launch }

    func allows(_ current: URL?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let launch, let current else { changed = true; return false }
        if launch != current { changed = true }
        return !changed
    }
}
