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
        if !allowsCustomHosts {
            // Exactly the production address: no other host, no other port.
            guard host == productionHost, url.port == nil else { return nil }
        }
        return url
    }
}
