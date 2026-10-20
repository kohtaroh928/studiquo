import Foundation

/// Which addresses in an AI reply may be opened.
///
/// An AI reply is text that other people can influence: a shared note or a retrieved
/// document can tell the model to end its answer with a link whose address carries
/// other text, and opening it would send that text to whoever owns the site. So a link
/// in a reply is opened only when it points at one of the sites listed here, in the
/// shape listed here, and is otherwise just text. The same rule applies to every reply,
/// whether or not the app can tell what the model was shown.
///
/// Adding a site is a security decision. Before adding one, check each of these and write
/// the answer in the commit message:
///  1. An attacker cannot read the requests made to it: no personal pages, shared documents,
///     link shorteners, or anything that logs to the page owner.
///  2. It has no way to send the visitor on to an address taken from the link (open
///     redirects, "go to this URL" pages, search that jumps to other sites).
///  3. No part of its address space can be registered by a stranger (subdomains for
///     users, project pages, custom domains).
///  4. The path shape below is as narrow as the site allows. Every part of an address
///     that the site accepts freely is a place to hide data.
enum AILinkPolicy {
    /// One site and the only path shape that is opened on it.
    struct AllowedSite: Equatable {
        /// A host matches when it is this domain or a subdomain of it (ja.wikipedia.org).
        let domain: String
        /// Everything after this prefix is a single plain name: no further "/", no query,
        /// no fragment, no namespace ("Special:", "User:"), no escaped delimiters.
        let pathPrefix: String
    }

    static let allowedSites: [AllowedSite] = [
        AllowedSite(domain: "wikipedia.org", pathPrefix: "/wiki/"),
    ]

    /// Longest address that is opened. A long address is where data is hidden.
    static let maxLength = 300

    /// The address to open, or nil when the link must stay plain text.
    static func openableURL(_ link: String?, allowedSites: [AllowedSite] = AILinkPolicy.allowedSites) -> URL? {
        guard let link, link.count <= maxLength,
              // Visible ASCII only: no spaces, controls, full-width or look-alike letters.
              link.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              // Every "%" starts a valid escape. Foundation quietly repairs a bad one ("%ZZ"
              // becomes "%25ZZ"), so what it parses is not what was written.
              hasOnlyValidEscapes(link),
              let components = URLComponents(string: link),
              let url = URL(string: link),
              components.scheme?.lowercased() == "https",
              // "https://wikipedia.org@evil.example/" names evil.example as the host.
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              // Nothing after the path: a query or a fragment can only carry data.
              components.percentEncodedQuery == nil, components.percentEncodedFragment == nil,
              let host = components.host?.lowercased(), !host.isEmpty,
              // Two parsers must agree on the host, and it must not hide behind escapes.
              url.host?.lowercased() == host, components.percentEncodedHost?.lowercased() == host
        else { return nil }
        // A host name is letters, digits and hyphens in dot-separated labels (RFC 1123), at
        // least two labels, not an IP address, no punycode.
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !host.contains("xn--"),
              labels.allSatisfy({ isHostLabel($0) }),
              !labels.allSatisfy({ $0.allSatisfy(\.isNumber) })
        else { return nil }
        guard let site = allowedSites.first(where: { matches(host, $0.domain.lowercased()) }),
              isPlainName(components.percentEncodedPath, after: site.pathPrefix)
        else { return nil }
        return url
    }

    private static func hasOnlyValidEscapes(_ link: String) -> Bool {
        let bytes = Array(link.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%") {
                guard i + 2 < bytes.count, isHex(bytes[i + 1]), isHex(bytes[i + 2]) else { return false }
                i += 3
            } else {
                i += 1
            }
        }
        return true
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }

    private static func matches(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    private static func isHostLabel(_ label: Substring) -> Bool {
        guard let first = label.first, let last = label.last, first != "-", last != "-" else { return false }
        return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// `path` is the prefix followed by one name. The name may be percent-encoded (Japanese
    /// article titles are), but may not hide a delimiter, a namespace or a dot segment.
    private static func isPlainName(_ path: String, after prefix: String) -> Bool {
        guard path.hasPrefix(prefix) else { return false }
        let name = String(path.dropFirst(prefix.count))
        guard !name.isEmpty, !name.contains("/"), let decoded = name.removingPercentEncoding else { return false }
        guard !decoded.contains(where: { "/\\?#:".contains($0) }), !decoded.allSatisfy({ $0 == "." }) else { return false }
        return !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }
}
