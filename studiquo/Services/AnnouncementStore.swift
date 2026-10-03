import Foundation

/// What an operator announcement is about. Unknown values (a kind added on
/// the server before this app version knows it) fall back to `.news` so a
/// newer server never makes an older app drop the item.
enum AnnouncementKind: String {
    case update, maintenance, important, news

    var titleKey: String { "announcements.kind.\(rawValue)" }

    var systemImage: String {
        switch self {
        case .update: "arrow.down.app"
        case .maintenance: "wrench.and.screwdriver"
        case .important: "exclamationmark.triangle"
        case .news: "megaphone"
        }
    }
}

/// One notice from the operators, already in the best available language —
/// the server picks the translation from the `lang` the app sends (see
/// mcp-server/src/announcements.js), so adding a language never needs an app
/// change.
struct Announcement: Codable, Identifiable, Equatable {
    let id: String
    let kind: String
    let title: String
    let body: String
    let link: String?
    let publishedAt: Date

    var kindValue: AnnouncementKind { AnnouncementKind(rawValue: kind) ?? .news }

    /// Only https links are ever opened, whatever the server sent.
    var linkURL: URL? {
        guard let link, let url = URL(string: link), url.scheme == "https" else { return nil }
        return url
    }

    static func decodeList(from data: Data) throws -> [Announcement] {
        struct Envelope: Decodable { let announcements: [Announcement] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Envelope.self, from: data).announcements
    }
}

/// The お知らせ inbox: fetches the public list, keeps the last good copy so
/// the screen still works offline, and remembers (per device) which items
/// have been opened. Announcements carry no personal data, so the request is
/// unauthenticated and works before sign-in.
@MainActor
final class AnnouncementStore: ObservableObject {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    static let cacheKey = "announcements.cache"
    static let readIDsKey = "announcements.readIDs"

    @Published private(set) var announcements: [Announcement]
    @Published private(set) var readIDs: Set<String>
    @Published private(set) var loadFailed = false

    private let defaults: UserDefaults
    private let fetch: Fetch
    private let endpoint: () -> URL
    private let languageCode: () -> String
    private let appVersion: () -> String?

    init(
        defaults: UserDefaults = .standard,
        fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) },
        endpoint: @escaping () -> URL = {
            MCPCloudCredentials.configuredEndpoint() ?? URL(string: WorkerAIProvider.defaultEndpoint)!
        },
        languageCode: @escaping () -> String = { AppLocale.current.identifier(.bcp47) },
        appVersion: @escaping () -> String? = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        }
    ) {
        self.defaults = defaults
        self.fetch = fetch
        self.endpoint = endpoint
        self.languageCode = languageCode
        self.appVersion = appVersion
        if let data = defaults.data(forKey: Self.cacheKey),
           let cached = try? Announcement.decodeList(from: data) {
            announcements = cached
        } else {
            announcements = []
        }
        readIDs = Set(defaults.stringArray(forKey: Self.readIDsKey) ?? [])
    }

    var unreadCount: Int { announcements.filter { !readIDs.contains($0.id) }.count }

    func isRead(_ announcement: Announcement) -> Bool { readIDs.contains(announcement.id) }

    func markRead(_ announcement: Announcement) {
        guard readIDs.insert(announcement.id).inserted else { return }
        persistReadIDs()
    }

    func markAllRead() {
        let all = Set(announcements.map(\.id))
        guard !all.isSubset(of: readIDs) else { return }
        readIDs.formUnion(all)
        persistReadIDs()
    }

    /// Silent on failure apart from `loadFailed`: a missed refresh just
    /// leaves the cached list in place.
    func refresh() async {
        var components = URLComponents(url: endpoint().appending(path: "api/announcements"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "lang", value: languageCode())]
        if let version = appVersion() { items.append(URLQueryItem(name: "appVersion", value: version)) }
        components?.queryItems = items
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await fetch(request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let fresh = try Announcement.decodeList(from: data)
            announcements = fresh
            loadFailed = false
            defaults.set(data, forKey: Self.cacheKey)
            // Forget read marks for items the server no longer lists.
            let live = Set(fresh.map(\.id))
            if !readIDs.isSubset(of: live) {
                readIDs.formIntersection(live)
                persistReadIDs()
            }
        } catch {
            loadFailed = true
        }
    }

    private func persistReadIDs() {
        defaults.set(Array(readIDs), forKey: Self.readIDsKey)
    }
}
