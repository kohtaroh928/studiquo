import Foundation

/// Which addresses in an AI reply may be opened.
///
/// An AI reply is text that other people can influence: a shared note or a retrieved
/// document can tell the model to end its answer with a link whose address carries
/// other text, and opening it would send that text to whoever owns the site. So a link
/// in a reply is opened only when its site is on this short list, and is otherwise just
/// text. The same rule applies to every reply, whether or not the app can tell what the
/// model was shown.
///
/// A site belongs on the list only if an attacker cannot read the requests made to it:
/// no personal pages, shared documents, link shorteners or anything that redirects to an
/// address in its query. Add a site here, with a test, after checking that.
enum AILinkPolicy {
    /// A host matches when it is one of these, or a subdomain of one (ja.wikipedia.org).
    static let allowedDomains: [String] = ["wikipedia.org"]

    /// Longest address that is opened. A long address is where data is hidden.
    static let maxLength = 300

    /// The address to open, or nil when the link must stay plain text.
    static func openableURL(_ link: String?, allowedDomains: [String] = AILinkPolicy.allowedDomains) -> URL? {
        guard let link, link.count <= maxLength,
              // Visible ASCII only: no spaces, controls, full-width or look-alike letters.
              link.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              let components = URLComponents(string: link),
              let url = URL(string: link),
              components.scheme?.lowercased() == "https",
              // "https://wikipedia.org@evil.example/" names evil.example as the host.
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(), !host.isEmpty,
              // Two parsers must agree on the host, and it must not hide behind escapes.
              url.host?.lowercased() == host, components.percentEncodedHost?.lowercased() == host,
              !host.contains("%"), !host.hasSuffix("."), !host.contains("xn--")
        else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        // A name has at least two non-empty labels and is not an IP address.
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }), !host.contains(":")
        else { return nil }
        guard allowedDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return url
    }
}
