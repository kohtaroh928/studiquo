import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit
import Security

private struct MCPSnapshot: Codable {
    let version: Int
    let exportedAt: Date
    let notebooks: [MCPNotebook]
    let flashcardDecks: [MCPDeck]
    let studyActivities: [MCPStudyActivity]
    let calendarEvents: [MCPCalendarEvent]
    let textDocuments: [MCPTextDocument]
    let slideDecks: [MCPSlideDeck]
}

private struct MCPTextDocument: Codable { let id: String; let title: String; let text: String }
private struct MCPSlideDeck: Codable { let id: String; let title: String; let slides: [MCPSlideSummary] }
private struct MCPSlideSummary: Codable { let title: String; let bullets: [String]; let notes: String }

private struct MCPNotebook: Codable { let id: String; let title: String; let pages: [MCPPage] }
private struct MCPPage: Codable { let id: String; let title: String; let recognizedText: String }
private struct MCPDeck: Codable { let id: String; let title: String; let cards: [MCPCard] }
private struct MCPCard: Codable { let question: String; let answer: String }
private struct MCPStudyActivity: Codable {
    let startedAt: Date
    let endedAt: Date
    let sourceTitle: String
    let correctCount: Int
    let totalCount: Int
}

private struct MCPCalendarEvent: Codable {
    let title: String
    let startDate: Date
    let endDate: Date
    let kind: String
    let notes: String
}
/// One instruction handed back by the connected model.
///
/// Every field is optional because a single shape carries all the action
/// types; `type` decides which of them are read. Unknown types are ignored, so
/// a newer server can send actions an older build simply skips.
private struct MCPPendingAction: Codable {
    let type: String
    let deckTitle: String?
    let cards: [MCPCard]?
    let title: String?
    let startDate: Date?
    let endDate: Date?
    let kind: String?
    let notes: String?
    /// `create_document`: the body, as lines. A line beginning with `# `,
    /// `## ` or `### ` becomes a heading; `- ` becomes a bullet.
    let body: String?
    /// `create_slides`
    let slides: [MCPSlide]?
    let theme: String?
}

private struct MCPSlide: Codable {
    let layout: String?
    let title: String?
    let bullets: [String]?
    let notes: String?
}

private struct StudyNotification: Identifiable {
    enum Destination { case calendar, none }
    let id: String
    let title: String
    let message: String
    /// The full body, shown only on the detail screen. University items carry
    /// the description their LMS published, which is often several
    /// paragraphs — far too much for a row in the list.
    let detail: String
    let date: Date
    let icon: String
    let tint: Color
    let destination: Destination
    /// Name of the institution this came from; `nil` for the app's own
    /// study reminders.
    let university: String?

    var relativeDate: String {
        NotificationLocale.relative(date)
    }
}

/// The bundle declares no Japanese localization, so `Locale.current` makes
/// `Foundation`'s date formatting fall back to English — "in 0 seconds" under
/// an otherwise Japanese interface. Dates are therefore formatted against the
/// language the user actually picked.
private enum NotificationLocale {
    static var locale: Locale {
        switch AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .system {
        case .english: Locale(identifier: "en_US")
        case .japanese, .system: Locale(identifier: "ja_JP")
        }
    }

    static func relative(_ date: Date) -> String {
        let isJapanese = locale.identifier.hasPrefix("ja")
        if abs(date.timeIntervalSinceNow) < 60 {
            return isJapanese ? "たった今" : "just now"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// The body of one notification, reached by tapping its row. University
/// announcements list only their subject in the feed, so this is where the
/// message itself is read.
private struct StudyNotificationDetail: View {
    let notification: StudyNotification
    let onOpenDestination: (StudyNotification) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: notification.icon)
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(notification.tint.gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        if let university = notification.university {
                            UniversityTag(name: university)
                        }
                        Text(notification.relativeDate)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Text(notification.title)
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)

                Text(NotificationLocale.absolute(notification.date))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()

                if notification.detail.isEmpty {
                    Text("このお知らせに本文はありません。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    Text(notification.detail)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if notification.destination == .calendar {
                    Button {
                        onOpenDestination(notification)
                    } label: {
                        Label("カレンダーで開く", systemImage: "calendar")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                }
            }
            .padding(20)
        }
        .navigationTitle("通知の詳細")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Marks an item as coming from the connected university rather than from
/// Studiquo itself.
private struct UniversityTag: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "building.columns.fill")
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.indigo)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.indigo.opacity(0.14), in: Capsule())
    }
}

/// The notification drop-down, modelled on the panel a university LMS shows
/// under its own bell: a header carrying mark-all-read / settings / close, a
/// scrolling list where each row is a subject line with its age and a link
/// into the full message, and a footer that opens the whole history.
///
/// Presented as a popover anchored to the bell rather than as a sheet, so it
/// reads as belonging to the button that opened it.
private struct StudyNotificationList: View {
    let notifications: [StudyNotification]
    let readIDs: Set<String>
    let onSelect: (StudyNotification) -> Void
    let onMarkAllRead: () -> Void
    let onMarkRead: (StudyNotification) -> Void
    let onOpenSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// The panel lists only the most recent few; the footer opens the rest.
    private static let previewCount = 8

    @State private var showsAll = false

    private var visibleNotifications: [StudyNotification] {
        showsAll ? notifications : Array(notifications.prefix(Self.previewCount))
    }

    private var hasUnread: Bool {
        notifications.contains { !readIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()

                if notifications.isEmpty {
                    ContentUnavailableView(
                        "新しい通知はありません",
                        systemImage: "bell.slash",
                        description: Text("予定や学習の進み具合、連携した大学からのお知らせをここに表示します。")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleNotifications) { notification in
                                row(for: notification)
                                Divider()
                            }
                        }
                    }

                    if notifications.count > Self.previewCount {
                        Divider()
                        Button {
                            showsAll.toggle()
                        } label: {
                            Text(showsAll ? "表示を減らす" : "すべてを表示する")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .navigationBarHidden(true)
        }
        .frame(minWidth: 380, idealWidth: 460, minHeight: 320, idealHeight: 560)
        .presentationCompactAdaptation(.popover)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("通知")
                .font(.subheadline.weight(.semibold))
            Spacer()
            HStack(spacing: 16) {
                Button(action: onMarkAllRead) {
                    Image(systemName: "checkmark")
                }
                .accessibilityLabel("すべて既読にする")
                .disabled(!hasUnread)

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("通知の設定")

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("閉じる")
            }
            .font(.subheadline)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(.bar)
    }

    /// Subject on top, then the age on the left and the link into the body on
    /// the right — the shape an LMS notification list uses, and the reason the
    /// message body itself is not repeated here.
    private func row(for notification: StudyNotification) -> some View {
        NavigationLink {
            StudyNotificationDetail(
                notification: notification,
                onOpenDestination: onSelect
            )
            .onAppear { onMarkRead(notification) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: notification.icon)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(notification.tint.gradient, in: Circle())

                    Text(notification.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    if !readIDs.contains(notification.id) {
                        Circle().fill(.blue).frame(width: 7, height: 7)
                            .padding(.top, 6)
                            .accessibilityLabel("未読")
                    }
                }

                HStack(spacing: 8) {
                    Text(notification.relativeDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("通知詳細を表示する")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.leading, 28)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(readIDs.contains(notification.id) ? Color.clear : Color.accentColor.opacity(0.06))
        }
        .buttonStyle(.plain)
    }
}

private struct FriendChatListPopover: View {
    @ObservedObject var store: FriendStore
    let onOpen: (FriendRecord) -> Void
    let onAddFriend: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("フレンド")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(action: onAddFriend) {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("フレンドを追加")
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("閉じる")
                    .padding(.leading, 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(.bar)

                Divider()

                if store.friends.isEmpty {
                    ContentUnavailableView(
                        "フレンドがいません",
                        systemImage: "person.2",
                        description: Text("フレンド画面から招待できます。")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(store.friends) { friend in
                                Button { onOpen(friend) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "person.crop.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(Color.accentColor)
                                            .frame(width: 32)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(friend.name)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)
                                            if let latest = store.messages(for: friend).last {
                                                Text(latest.text)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            } else {
                                                Text("チャットを開く")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        if let count = store.unreadCounts[friend.id], count > 0 {
                                            Text("\(min(count, 99))")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(.white)
                                                .frame(minWidth: 20, minHeight: 20)
                                                .background(.red, in: Circle())
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                }
            }
            .navigationBarHidden(true)
        }
        .frame(minWidth: 380, idealWidth: 430, minHeight: 320, idealHeight: 520)
        .presentationCompactAdaptation(.popover)
    }
}

/// What the tab bar's "+" opens: the same notes and decks the home screen
/// lists, so a second tab can be opened without leaving the editor.
/// A locked PDF that has just been opened, carried into the "remove
/// password?" prompt. The password lives only as long as this value.
private struct PendingRemoval {
    let url: URL
    let password: String
}

private struct TabPickerView: View {
    let notebooks: [Notebook]
    let decks: [FlashcardDeck]
    let documents: [TextDocument]
    let slideDecks: [SlideDeck]
    let onSelectNotebook: (Notebook) -> Void
    let onSelectDeck: (FlashcardDeck) -> Void
    let onSelectDocument: (TextDocument) -> Void
    let onSelectSlideDeck: (SlideDeck) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredNotebooks: [Notebook] {
        guard !searchText.isEmpty else { return notebooks }
        return notebooks.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredDecks: [FlashcardDeck] {
        guard !searchText.isEmpty else { return decks }
        return decks.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredDocuments: [TextDocument] {
        guard !searchText.isEmpty else { return documents }
        return documents.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredSlideDecks: [SlideDeck] {
        guard !searchText.isEmpty else { return slideDecks }
        return slideDecks.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("ノート・PDF") {
                    if filteredNotebooks.isEmpty {
                        Text("ノートはありません").foregroundStyle(.secondary)
                    }
                    ForEach(filteredNotebooks) { notebook in
                        Button {
                            onSelectNotebook(notebook)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: notebook.containsPDF ? "doc.richtext" : "note.text")
                                    .foregroundStyle(notebook.containsPDF ? .red : .blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(notebook.title).lineLimit(1)
                                    Text("\(notebook.sortedPages.count)ページ")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("暗記帳") {
                    if filteredDecks.isEmpty {
                        Text("暗記帳はありません").foregroundStyle(.secondary)
                    }
                    ForEach(filteredDecks) { deck in
                        Button {
                            onSelectDeck(deck)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "rectangle.on.rectangle.angled")
                                    .foregroundStyle(.indigo)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(deck.title).lineLimit(1)
                                    Text("\(deck.sortedCards.count)枚")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !filteredDocuments.isEmpty {
                    Section("文書") {
                        ForEach(filteredDocuments) { document in
                            Button { onSelectDocument(document) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.text").foregroundStyle(.teal)
                                    Text(document.title).lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !filteredSlideDecks.isEmpty {
                    Section("スライド") {
                        ForEach(filteredSlideDecks) { deck in
                            Button { onSelectSlideDeck(deck) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "rectangle.on.rectangle").foregroundStyle(.orange)
                                    Text(deck.title).lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "名前で検索")
            .navigationTitle("タブを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
        // A fixed portrait sheet. It used to offer both a large and a medium
        // detent, so the list could be dragged into a half-height panel that
        // showed two or three notes at a time.
        .modifier(FixedSheetSize(shape: .portrait))
        .presentationDragIndicator(.hidden)
    }
}

private enum AppLanguage: String, CaseIterable, Identifiable {
    case system, japanese, english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L("端末の設定に合わせる")
        case .japanese: L("日本語")
        case .english: "English"
        }
    }
}

/// App-wide preferences, opened from the gear beside the toolbar's plus.
/// The chosen language drives `\.locale` at the scene root (`StudiquoApp`),
/// so switching it here updates every screen immediately — no restart.
private struct AppSettingsView: View {
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
    @AppStorage("studyTimeTrackingEnabled") private var studyTimeTrackingEnabled = true
    @AppStorage("leftHandedMode") private var isLeftHandedMode = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("言語", selection: $appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("言語")
                } footer: {
                    Text("選んだ言語はすぐに反映されます。")
                }

                Section {
                    Toggle("勉強時間を記録する", isOn: $studyTimeTrackingEnabled)
                } header: {
                    Text("学習記録")
                } footer: {
                    Text("ノート・暗記帳・文書・スライドを開いている間の時間だけを記録します。オフにすると勉強時間と連続学習日数の記録を止めます。")
                }

                Section {
                    Toggle("左利きモード", isOn: $isLeftHandedMode)
                } header: {
                    Text("描画")
                } footer: {
                    Text("描画バーの並びを左利き向けに反転します。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}

enum MCPCloudCredentials {
    private static let service = "com.yabuko.studiquo.mcp"
    private static let account = "cloud-token"
    /// How long a generated token stays valid before the server starts rejecting it.
    /// Keep in sync with `VALIDITY_SECONDS` in mcp-server/src/token.js.
    static let validityPeriod: TimeInterval = 90 * 24 * 60 * 60

    static func loadOrCreateToken() -> String {
        if let value = currentToken(), value.count >= 32, !isExpired(value) { return value }
        return generateAndSaveNewToken()
    }

    /// True once the token's embedded issue date is older than `validityPeriod`,
    /// or if the token predates this format and carries no issue date at all.
    static func isExpired(_ token: String) -> Bool {
        guard let issuedAt = issuedAt(of: token) else { return true }
        return Date().timeIntervalSince(issuedAt) > validityPeriod
    }

    /// Tokens are `"<issued-at epoch seconds>.<random secret>"` so the server
    /// can enforce expiry without having to remember when it first saw a token.
    private static func issuedAt(of token: String) -> Date? {
        guard let dot = token.firstIndex(of: "."),
              let epochSeconds = Double(token[token.startIndex..<dot]) else { return nil }
        return Date(timeIntervalSince1970: epochSeconds)
    }

    /// Mints a token with a fresh issue date, saves it, and returns it. Every
    /// place that hands the user a "new" token (auto-rotation, the manual
    /// "generate a new token" button) must go through this, not build its own
    /// UUID string, or the result won't carry the issue date the server checks.
    static func generateAndSaveNewToken() -> String {
        let value = makeToken()
        save(value)
        return value
    }

    private static func makeToken() -> String {
        let issuedAt = Int(Date().timeIntervalSince1970)
        return "\(issuedAt).\(makeRandomValue())"
    }

    /// A random secret half for a "<issued-at epoch>.<random>" token — used
    /// both when minting this device's own token above, and by
    /// AppleSignInService/GoogleSignInService when they ask the server to
    /// mint one from a random half they supply.
    static func makeRandomValue() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Reads the token without generating a new one; nil if none exists yet.
    static func currentToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    /// Deletes the local token without telling the server. Prefer `revoke()`,
    /// which also asks the server to reject the old value if it's ever replayed.
    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }

    /// Forgets this device's cloud token and tells the server to reject it
    /// going forward, so a copy made before logout (e.g. from a compromised
    /// backup) can't keep syncing after the user signs out. Best-effort: the
    /// local token is cleared first regardless of whether the network call
    /// succeeds, so logout is never blocked on connectivity.
    static func revoke() async {
        guard let token = currentToken() else { return }
        clear()
        guard let endpoint = configuredEndpoint() else { return }
        var request = URLRequest(url: endpoint.appending(path: "api/session/revoke"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }

    /// The Worker endpoint every cloud request (sync, AI, sign-in, revoke)
    /// should target: the user's custom endpoint from settings if they've set
    /// one and it's a valid https URL, otherwise the built-in default.
    static func configuredEndpoint() -> URL? {
        var raw = (UserDefaults.standard.string(forKey: "mcpCloudEndpoint") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { raw = WorkerAIProvider.defaultEndpoint }
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Notebook.updatedAt, order: .reverse) private var allNotebooks: [Notebook]
    @Query(sort: \FlashcardDeck.updatedAt, order: .reverse) private var flashcardDecks: [FlashcardDeck]
    @Query(sort: \TextDocument.updatedAt, order: .reverse) private var textDocuments: [TextDocument]
    @Query(sort: \SlideDeck.updatedAt, order: .reverse) private var slideDecks: [SlideDeck]
    @Query(sort: \CalendarEvent.startDate) private var calendarEvents: [CalendarEvent]
    @Query(sort: \StudyActivity.startedAt, order: .reverse) private var studyActivities: [StudyActivity]
    @AppStorage("libraryFolderNames") private var folderNamesStorage = ""
    @AppStorage("libraryFolderCreatedAt") private var folderCreatedAtStorage = "{}"
    @AppStorage("favoriteFolderPaths") private var favoriteFolderPathsStorage = ""
    @AppStorage("notebookLibraryMetadataVersion") private var notebookLibraryMetadataVersion = 0

    @State private var selectedNotebook: Notebook?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var libraryMode: LibraryMode = .documents
    @State private var selectedFolder: String?
    @State private var sortOption: NotebookSortOption = .updatedNewest
    @State private var searchText = ""
    @State private var isImportingFiles = false
    @State private var isImportingBackup = false
    /// A locked PDF waiting for its password before it can be imported.
    @State private var pdfPendingImport: URL?
    /// A locked PDF the student chose to strip the password from and save.
    @State private var pdfPendingUnlock: URL?
    @State private var pdfPasswordEntry = ""
    @State private var pdfPasswordError: String?
    /// Set when `stableCopy` couldn't preserve a picked PDF long enough to
    /// prompt for its password — a dead end distinct from a wrong password.
    @State private var pdfPrepareError: String?
    /// Set when password removal was requested on a PDF that isn't
    /// protected — a dead end, not a password prompt to retry.
    @State private var pdfNotProtectedError: String?
    /// The finished password-free copy, handed to a share sheet.
    @State private var pdfUnlockedResult: IdentifiableURL?
    /// Shows the PDF-only picker for the password-removal tool.
    @State private var isPickingPDFToUnlock = false
    /// Set after a locked PDF is opened during import, to offer removing its
    /// password (holds the password just long enough to write the copy).
    @State private var pdfRemovalOffer: PendingRemoval?
    @State private var backupURL: IdentifiableURL?
    @State private var previewURL: IdentifiableURL?
    @State private var isDownloadingFriendAttachment = false
    @State private var openNotebooks: [Notebook] = []
    @State private var openStudyNotebooks: [Notebook] = []
    @State private var openFlashcardDecks: [FlashcardDeck] = []
    @State private var openWebTabs: [WebTabInfo] = []
    /// One tab per AI conversation, kept here because the tab bar lives here
    /// while the conversations themselves are owned by the open editor.
    @State private var openAIChatTabs: [AIChatTabInfo] = []
    @State private var selectedAIChatTabID: PersistentIdentifier?
    @StateObject private var editorSplitState = EditorSplitState()
    @StateObject private var friendStore = FriendStore()
    @State private var showsAutomaticBackups = false
    @State private var newNotebookName = ""
    @State private var isShowingNewNotebookAlert = false
    @State private var newNotebookTemplate: PageTemplate = .ruled
    @State private var notebookToRename: Notebook?
    @State private var renameText = ""
    @State private var showsEmptyTrashConfirmation = false
    @State private var isShowingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var notebookToEditTags: Notebook?
    @State private var tagsText = ""
    @State private var expandedSidebarFolders: Set<String> = []
    @State private var folderDropTarget: String?
    @State private var studyNotebook: Notebook?
    @State private var selectedFlashcardDeck: FlashcardDeck?
    @State private var selectedTextDocument: TextDocument?
    @State private var selectedSlideDeck: SlideDeck?
    @State private var openTextDocuments: [TextDocument] = []
    @State private var openSlideDecks: [SlideDeck] = []
    @State private var isShowingNewDocumentAlert = false
    @State private var newDocumentName = ""
    @State private var isShowingNewSlideDeckAlert = false
    @State private var newSlideDeckName = ""
    @State private var isShowingNewFlashcardDeckAlert = false
    @State private var newFlashcardDeckName = ""
    @State private var homeSection: HomeSection = .notes
    @AppStorage("mcpCloudEndpoint") private var mcpCloudEndpoint = WorkerAIProvider.defaultEndpoint
    @State private var mcpCloudToken = MCPCloudCredentials.loadOrCreateToken()
    @State private var showsMCPCloudSettings = false
    @State private var mcpCloudStatus = ""
    @State private var isMCPCloudSyncing = false
    @State private var isMCPCloudTokenVisible = false
    @State private var showsNotifications = false
    @State private var showsAppSettings = false
    @State private var showsProfile = false
    @AppStorage("profileImage") private var profileImageData = Data()
    @State private var showsTabPicker = false
    @State private var cachedStudyNotifications: [StudyNotification] = []
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("readStudyNotificationIDs") private var readStudyNotificationIDsStorage = ""

    private enum HomeSection: String, CaseIterable, Identifiable {
        case notes = "ノート"
        case calendar = "カレンダー"
        case friends = "フレンド"
        var id: String { rawValue }
        var icon: String {
            switch self { case .notes: "note.text"; case .calendar: "calendar"; case .friends: "person.2" }
        }
        var title: String { L(rawValue) }
    }

    private var folderNames: [String] {
        folderNamesStorage.split(separator: "\n").map(String.init)
    }

    private var folderCreatedAt: [String: TimeInterval] {
        guard let data = folderCreatedAtStorage.data(using: .utf8),
              let dates = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else {
            return [:]
        }
        return dates
    }

    private var favoriteFolderPaths: Set<String> {
        Set(favoriteFolderPathsStorage.split(separator: "\n").map(String.init))
    }

    private var sortedFolderNames: [String] {
        folderNames.sorted { first, second in
            switch sortOption {
            case .createdNewest:
                return (folderCreatedAt[first] ?? 0) > (folderCreatedAt[second] ?? 0)
            case .createdOldest:
                return (folderCreatedAt[first] ?? 0) < (folderCreatedAt[second] ?? 0)
            case .nameDescending:
                return first.localizedStandardCompare(second) == .orderedDescending
            default:
                return first.localizedStandardCompare(second) == .orderedAscending
            }
        }
    }

    private var visibleFolderPaths: [String] {
        sortedFolderNames.filter { parentFolder(of: $0) == selectedFolder }
    }

    private func parentFolder(of path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }

    private func folderDisplayName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private var isHomeScreen: Bool {
        libraryMode == .documents && selectedFolder == nil
    }

    private var homeNotebooks: [Notebook] {
        allNotebooks
            .filter { !$0.isTrashed && $0.folderName.isEmpty }
            .filter { notebook in
                searchText.isEmpty
                    || notebook.title.localizedCaseInsensitiveContains(searchText)
                    || notebook.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
            .sorted(by: sortOption.comparator)
    }

    private var visibleNotebooks: [Notebook] {
        let filtered = allNotebooks.filter { notebook in
            let belongsToMode: Bool
            if let selectedFolder {
                belongsToMode = !notebook.isTrashed && notebook.folderName == selectedFolder
            } else {
                switch libraryMode {
                case .documents: belongsToMode = !notebook.isTrashed
                case .favorites: belongsToMode = !notebook.isTrashed && notebook.isFavorite
                case .pdfs: belongsToMode = !notebook.isTrashed && notebook.containsPDF
                case .studyCards: belongsToMode = false
                case .textDocuments: belongsToMode = false
                case .slides: belongsToMode = false
                case .trash: belongsToMode = notebook.isTrashed
                }
            }
            let matchesSearch = searchText.isEmpty
                || notebook.title.localizedCaseInsensitiveContains(searchText)
                || notebook.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            return belongsToMode && matchesSearch
        }
        return filtered.sorted(by: sortOption.comparator)
    }

    /// True for anything pulled in from a connected university calendar,
    /// including entries saved by the Waseda-only build.
    private func isUniversityEvent(_ event: CalendarEvent) -> Bool {
        event.externalSource == UniversityCalendar.externalSource
            || event.externalSource == "waseda-moodle"
    }

    private func makeStudyNotifications() -> [StudyNotification] {
        let calendar = Calendar.current
        let now = Date.now
        let weekFromNow = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        // University items are kept for a longer horizon than the app's own
        // reminders: an announcement is worth reading well before its
        // deadline is imminent.
        let universityHorizon = calendar.date(byAdding: .day, value: 60, to: now) ?? now

        var items = calendarEvents
            .filter { event in
                guard event.endDate >= now else { return false }
                return isUniversityEvent(event)
                    ? event.startDate <= universityHorizon
                    : event.startDate <= weekFromNow
            }
            .map { event -> StudyNotification in
                let isToday = calendar.isDateInToday(event.startDate)
                let isTomorrow = calendar.isDateInTomorrow(event.startDate)
                let timing = isToday
                    ? L("今日")
                    : (isTomorrow ? L("明日") : event.startDate.formatted(.dateTime.month().day().weekday(.abbreviated)))

                if isUniversityEvent(event) {
                    // The subject alone goes in the feed; `detail` carries the
                    // announcement body for the detail screen.
                    return StudyNotification(
                        id: "university-\(event.externalID ?? event.title)",
                        title: event.title,
                        message: "",
                        detail: event.notes,
                        date: event.startDate,
                        icon: "building.columns.fill",
                        tint: .indigo,
                        destination: .calendar,
                        university: event.externalSourceName
                            ?? UniversityCalendar.storedName
                            ?? L("大学")
                    )
                }

                return StudyNotification(
                    id: "event-\(event.createdAt.timeIntervalSince1970)-\(event.title)",
                    title: event.kind == .test
                        ? L("テストが近づいています")
                        : L("予定を確認しましょう"),
                    message: L("\(timing)・\(event.startDate.formatted(date: .omitted, time: .shortened))  \(event.title)"),
                    detail: event.notes.isEmpty
                        ? L("\(timing) \(event.startDate.formatted(date: .omitted, time: .shortened))  \(event.title)")
                        : event.notes,
                    date: event.startDate,
                    icon: event.kind.icon,
                    tint: event.kind == .test ? .red : (event.kind == .classLesson ? .blue : .orange),
                    destination: .calendar,
                    university: nil
                )
            }

        let todayActivities = studyActivities.filter { calendar.isDateInToday($0.startedAt) }
        let todayMinutes = Int(todayActivities.reduce(0) { $0 + $1.duration }) / 60
        if todayMinutes >= 25 {
            items.append(StudyNotification(
                id: "achievement-\(calendar.startOfDay(for: now).timeIntervalSince1970)-25",
                title: L("今日の学習、いいペースです"),
                message: L("合計\(todayMinutes)分学習しました。この調子で続けましょう。"),
                detail: L("今日はここまでで合計\(todayMinutes)分学習しました。この調子で続けましょう。"),
                date: now,
                icon: "checkmark.seal.fill",
                tint: .green,
                destination: .none,
                university: nil
            ))
        } else if todayActivities.isEmpty {
            items.append(StudyNotification(
                id: "reminder-\(calendar.startOfDay(for: now).timeIntervalSince1970)",
                title: L("今日の学習を始めませんか？"),
                message: L("まずは15分。ノートや暗記カードを開いて、短く始めてみましょう。"),
                detail: L("まずは15分。ノートや暗記カードを開いて、短く始めてみましょう。"),
                date: now,
                icon: "timer",
                tint: .orange,
                destination: .none,
                university: nil
            ))
        }
        return items.sorted { $0.date < $1.date }
    }

    private var readStudyNotificationIDs: Set<String> {
        Set(readStudyNotificationIDsStorage.split(separator: "\n").map(String.init))
    }

    private var unreadStudyNotificationCount: Int {
        cachedStudyNotifications.filter { !readStudyNotificationIDs.contains($0.id) }.count
    }

    /// The app's split-view layout. The calendar hides the sidebar and
    /// removes its reveal toggle (see `CalendarHomeView`), so the “すべて・
    /// お気に入り” list is gone there rather than one tap away.
    private var librarySplitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List {
                if selectedNotebook != nil || selectedFlashcardDeck != nil
                    || selectedTextDocument != nil || selectedSlideDeck != nil {
                    Section {
                        Button {
                            returnToHome()
                        } label: {
                            Label("ホーム", systemImage: "house.fill")
                        }
                        .buttonStyle(.plain)
                    }

                    Section {
                        ForEach(sortedFolderNames, id: \.self) { folder in
                            sidebarFolderRow(folder)
                        }
                        let sidebarDocuments = textDocumentsInFolder("")
                        let sidebarSlides = slideDecksInFolder("")
                        ForEach(homeNotebooks) { notebook in
                            sidebarNotebookButton(notebook)
                        }
                        ForEach(flashcardDecks.filter { $0.folderName.isEmpty }) { deck in
                            sidebarFlashcardDeckButton(deck)
                        }
                        ForEach(sidebarDocuments) { document in
                            sidebarTextDocumentButton(document)
                        }
                        ForEach(sidebarSlides) { deck in
                            sidebarSlideDeckButton(deck)
                        }
                    }
                } else {
                    Section("ライブラリ") {
                        ForEach(LibraryMode.allCases) { mode in
                            Button {
                                libraryMode = mode
                                selectedFolder = nil
                            } label: {
                                HStack {
                                    Label(mode.title, systemImage: mode.icon)
                                    Spacer()
                                    if libraryMode == mode {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Section {
                        ForEach(visibleFolderPaths, id: \.self) { folder in
                            Button {
                                selectedFolder = folder
                                libraryMode = .documents
                            } label: {
                                HStack {
                                    Label(folderDisplayName(folder), systemImage: "folder")
                                    Spacer()
                                    if selectedFolder == folder {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .dropDestination(for: String.self) { items, _ in
                                handleFolderDrop(items, into: folder)
                            }
                        }
                    } header: {
                        HStack {
                            Text("フォルダ")
                            Spacer()
                            Button { isShowingNewFolderAlert = true } label: { Image(systemName: "plus") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .navigationTitle("ノート")
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.86, green: 0.93, blue: 1.0))
        } detail: {
            if let selectedNotebook, !selectedNotebook.isTrashed {
                VStack(spacing: 0) {
                    notebookTabBar
                    Divider()
                    ProtectedNotebookView(
                        notebook: selectedNotebook,
                        columnVisibility: $columnVisibility,
                        onHome: returnToHome
                    )
                        .id(selectedNotebook.persistentModelID)
                        .environmentObject(editorSplitState)
                        .environmentObject(friendStore)
                }
            } else if let selectedFlashcardDeck {
                VStack(spacing: 0) {
                    notebookTabBar
                    Divider()
                    FlashcardDeckView(deck: selectedFlashcardDeck, onHome: returnToHome)
                        .id(selectedFlashcardDeck.persistentModelID)
                }
            } else if let selectedTextDocument {
                VStack(spacing: 0) {
                    notebookTabBar
                    Divider()
                    TextDocumentView(document: selectedTextDocument, onHome: returnToHome)
                        .id(selectedTextDocument.persistentModelID)
                }
            } else if let selectedSlideDeck {
                VStack(spacing: 0) {
                    notebookTabBar
                    Divider()
                    SlideDeckView(deck: selectedSlideDeck, onHome: returnToHome)
                        .id(selectedSlideDeck.persistentModelID)
                }
            } else {
                homeDashboard
            }
        }
    }

    /// Calendar and friends are shown full-width from the home dashboard —
    /// neither inherits the notebook library sidebar.
    private var isAuxiliaryHomeFullScreen: Bool {
        homeSection == .calendar || homeSection == .friends
    }

    var body: some View {
        Group {
            if isAuxiliaryHomeFullScreen {
                // A plain navigation stack keeps auxiliary home screens out
                // of the notebook split view while still providing a toolbar.
                NavigationStack { homeDashboard }
            } else {
                librarySplitView
            }
        }
        .sheet(isPresented: $isShowingNewNotebookAlert) {
            NewNotebookSheet(
                name: $newNotebookName,
                selectedTemplate: $newNotebookTemplate,
                onCancel: {
                    newNotebookName = ""
                    newNotebookTemplate = .ruled
                    isShowingNewNotebookAlert = false
                },
                onCreate: {
                    createBlankNotebook(template: newNotebookTemplate)
                    newNotebookTemplate = .ruled
                    isShowingNewNotebookAlert = false
                }
            )
        }
        .alert("新規フォルダ", isPresented: $isShowingNewFolderAlert) {
            TextField("フォルダ名", text: $newFolderName)
            Button("キャンセル", role: .cancel) { newFolderName = "" }
            Button("作成") { createFolder() }
        }
        .alert("新規文書", isPresented: $isShowingNewDocumentAlert) {
            TextField("文書名", text: $newDocumentName)
            Button("キャンセル", role: .cancel) { newDocumentName = "" }
            Button("作成") { createTextDocument() }
        } message: {
            Text("見出しや箇条書きを使って、レポートや下書きを書けます。")
        }
        .alert("新規スライド", isPresented: $isShowingNewSlideDeckAlert) {
            TextField("スライド名", text: $newSlideDeckName)
            Button("キャンセル", role: .cancel) { newSlideDeckName = "" }
            Button("作成") { createSlideDeck() }
        } message: {
            Text("レイアウトを選んでスライドを作り、そのまま発表できます。")
        }
        .alert("新規暗記帳", isPresented: $isShowingNewFlashcardDeckAlert) {
            TextField("暗記帳の名前", text: $newFlashcardDeckName)
            Button("キャンセル", role: .cancel) { newFlashcardDeckName = "" }
            Button("作成") { createFlashcardDeck() }
        } message: {
            Text("作成後、1枚目の問題と答えを入力します。")
        }
        .alert("名前を変更", isPresented: Binding(
            get: { notebookToRename != nil },
            set: { if !$0 { notebookToRename = nil } }
        )) {
            TextField("ノート名", text: $renameText)
            Button("キャンセル", role: .cancel) { notebookToRename = nil }
            Button("変更") { renameNotebook() }
        }
        .alert("タグを編集", isPresented: Binding(
            get: { notebookToEditTags != nil },
            set: { if !$0 { notebookToEditTags = nil } }
        )) {
            TextField("例：数学, 授業, 重要", text: $tagsText)
            Button("キャンセル", role: .cancel) { notebookToEditTags = nil }
            Button("保存") { saveTags() }
        } message: {
            Text("複数のタグはカンマで区切ってください。")
        }
        .sheet(isPresented: $isImportingFiles) {
            FileImportPicker { urls in
                // Dismiss the picker first, then import on the next runloop
                // turn. Importing a locked PDF raises a password alert, and
                // presenting that in the same transaction that dismisses this
                // sheet made the alert get dropped — which is why a protected
                // PDF slipped through with no prompt and came in blank.
                isImportingFiles = false
                let picked = urls
                DispatchQueue.main.async { picked.forEach(importFile) }
            } onCancel: {
                isImportingFiles = false
            }
        }
        .fileImporter(isPresented: $isPickingPDFToUnlock, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            beginPasswordRemoval(for: url)
        }
        .fileImporter(isPresented: $isImportingBackup, allowedContentTypes: [.json], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls {
                    if let notebook = NotebookBackupService.restore(from: url) {
                        modelContext.insert(notebook)
                        openNotebookTab(notebook)
                        selectedNotebook = notebook
                    }
                }
            }
        }
        .sheet(item: $backupURL) { wrapped in
            ShareSheet(items: [wrapped.url])
        }
        // Downloading a friend's attachment (see downloadAndPreviewFriendAttachment)
        // used to give no feedback at all while in flight — tapping it just
        // looked like nothing happened until the preview eventually opened,
        // or silently did nothing at all if it failed.
        .overlay {
            if isDownloadingFriendAttachment {
                ProgressView("読み込み中…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .fullScreenCover(item: $previewURL) { wrapped in
            NavigationStack {
                DocumentPreview(url: wrapped.url)
                    .ignoresSafeArea()
                    .navigationTitle(wrapped.url.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("閉じる") { previewURL = nil }
                        }
                    }
            }
        }
        .sheet(item: $pdfUnlockedResult) { wrapped in
            ShareSheet(items: [wrapped.url])
        }
        .alert("PDFのパスワード", isPresented: pdfPasswordPromptShown) {
            SecureField("パスワード", text: $pdfPasswordEntry)
            Button("OK", action: submitPDFPassword)
            Button("キャンセル", role: .cancel, action: cancelPDFPassword)
        } message: {
            Text(pdfPasswordError ?? "このPDFにはパスワードがかかっています。開くパスワードを入力してください。")
        }
        .alert("PDFを準備できませんでした", isPresented: Binding(
            get: { pdfPrepareError != nil },
            set: { if !$0 { pdfPrepareError = nil } }
        )) {
            Button("OK", role: .cancel) { pdfPrepareError = nil }
        } message: {
            Text(pdfPrepareError ?? "")
        }
        .alert("パスワードは設定されていません", isPresented: Binding(
            get: { pdfNotProtectedError != nil },
            set: { if !$0 { pdfNotProtectedError = nil } }
        )) {
            Button("OK", role: .cancel) { pdfNotProtectedError = nil }
        } message: {
            Text(pdfNotProtectedError ?? "")
        }
        .confirmationDialog(
            "パスワードを削除しますか？",
            isPresented: pdfRemovalOfferShown,
            titleVisibility: .visible
        ) {
            Button("パスワードなしで保存") {
                guard let offer = pdfRemovalOffer else { return }
                pdfRemovalOffer = nil
                do {
                    let output = try PDFPasswordService.removePassword(
                        from: offer.url,
                        password: offer.password,
                        to: PDFPasswordService.destinationURL(for: offer.url)
                    )
                    pdfUnlockedResult = IdentifiableURL(url: output)
                } catch {
                    pdfPasswordError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            Button("そのまま", role: .cancel) { pdfRemovalOffer = nil }
        } message: {
            Text("このPDFはノートに取り込みました。パスワードを削除したPDFも保存できます。")
        }
        .sheet(isPresented: $showsAutomaticBackups) {
            AutomaticBackupRestoreView { url in
                if let notebook = NotebookBackupService.restore(from: url) {
                    modelContext.insert(notebook)
                    openNotebookTab(notebook)
                    selectedNotebook = notebook
                }
            }
        }
        .sheet(isPresented: $showsMCPCloudSettings) {
            NavigationStack {
                Form {
                    Section("Cloudflare MCP") {
                        LabeledContent("サーバーURL") {
                            HStack {
                                TextField("https://studiquo-mcp.example.workers.dev", text: $mcpCloudEndpoint)
                                    .multilineTextAlignment(.trailing)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                Button {
                                    let endpoint = mcpCloudEndpoint
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                                    UIPasteboard.general.string = endpoint.hasSuffix("/mcp")
                                        ? endpoint
                                        : "\(endpoint)/mcp"
                                    mcpCloudStatus = L("MCP URLをコピーしました。")
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("MCP URLをコピー")
                                .disabled(mcpCloudEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }

                        LabeledContent("接続トークン") {
                            HStack {
                                Group {
                                    if isMCPCloudTokenVisible {
                                        TextField("接続トークン", text: $mcpCloudToken)
                                    } else {
                                        SecureField("接続トークン", text: $mcpCloudToken)
                                    }
                                }
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                                Button {
                                    isMCPCloudTokenVisible.toggle()
                                } label: {
                                    Image(systemName: isMCPCloudTokenVisible ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(isMCPCloudTokenVisible ? L("トークンを隠す") : L("トークンを表示"))

                                Button {
                                    UIPasteboard.general.string = mcpCloudToken
                                    mcpCloudStatus = L("接続トークンをコピーしました。")
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("接続トークンをコピー")
                                .disabled(mcpCloudToken.count < 32)
                            }
                        }
                        Button("新しいトークンを生成", systemImage: "arrow.clockwise") {
                            mcpCloudToken = MCPCloudCredentials.generateAndSaveNewToken()
                        }
                    }
                    Section {
                        Button("今すぐ同期", systemImage: "icloud.and.arrow.up") {
                            Task { await syncMCPCloud() }
                        }
                        .disabled(isMCPCloudSyncing || mcpCloudEndpoint.isEmpty || mcpCloudToken.count < 32)
                        if isMCPCloudSyncing { ProgressView() }
                        if !mcpCloudStatus.isEmpty { Text(mcpCloudStatus).foregroundStyle(.secondary) }
                    } footer: {
                        Text("先に「今すぐ同期」を実行してください。GeminiにはURLとトークンを設定します。Claude・ChatGPTではURLを登録するとStudiquoの認証画面が開きます。トークンは他人へ共有しないでください。")
                    }
                }
                .navigationTitle("MCPクラウド連携")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") {
                            MCPCloudCredentials.save(mcpCloudToken)
                            showsMCPCloudSettings = false
                        }
                    }
                }
            }
        }
        .sheet(item: $studyNotebook) { notebook in
            StudySessionView(notebook: notebook)
        }
        .sheet(isPresented: $showsAppSettings) {
            AppSettingsView()
        }
        .sheet(isPresented: $showsProfile) {
            UserProfileView()
        }
        .sheet(isPresented: $showsTabPicker) {
            TabPickerView(
                notebooks: allNotebooks.filter { !$0.isTrashed },
                decks: flashcardDecks.filter { !$0.isTrashed },
                documents: textDocuments.filter { !$0.isTrashed },
                slideDecks: slideDecks.filter { !$0.isTrashed },
                onSelectNotebook: { notebook in
                    showsTabPicker = false
                    selectNotebookTab(notebook)
                },
                onSelectDeck: { deck in
                    showsTabPicker = false
                    selectFlashcardTab(deck)
                },
                onSelectDocument: { document in
                    showsTabPicker = false
                    openTextDocument(document)
                },
                onSelectSlideDeck: { deck in
                    showsTabPicker = false
                    openSlideDeck(deck)
                }
            )
        }
        .onChange(of: libraryMode) { _, _ in
            if selectedFolder == nil { selectedNotebook = nil }
            searchText = ""
        }
        .onChange(of: selectedNotebook) { _, notebook in
            guard let notebook, !notebook.isTrashed else {
                columnVisibility = .detailOnly
                return
            }
            openNotebookTab(notebook)
            columnVisibility = .detailOnly
        }
        .onChange(of: selectedFlashcardDeck) { _, deck in
            guard let deck else { return }
            openFlashcardDeckTab(deck)
            columnVisibility = .detailOnly
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("StudiquoOpenNotebookTab"))) { notification in
            if let deck = notification.object as? FlashcardDeck {
                openFlashcardDeckTab(deck)
            } else if let notebook = notification.object as? Notebook {
                openNotebookTab(notebook)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .studiquoOpenAIChatTab)) { notification in
            guard let tab = notification.object as? AIChatTabInfo else { return }
            if let index = openAIChatTabs.firstIndex(where: { $0.id == tab.id }) {
                // Already open — this is a rename, from the thread being
                // titled after its first message.
                openAIChatTabs[index] = tab
            } else {
                openAIChatTabs.append(tab)
            }
            selectedAIChatTabID = tab.id
        }
        .onReceive(NotificationCenter.default.publisher(for: .studiquoCloseAIChatTab)) { notification in
            guard let id = notification.object as? PersistentIdentifier else { return }
            closeAIChatTab(id)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("StudiquoOpenWebTab"))) { notification in
            guard let tab = notification.object as? WebTabInfo else { return }
            if let index = openWebTabs.firstIndex(where: { $0.id == tab.id }) {
                openWebTabs[index] = tab
            } else {
                openWebTabs.append(tab)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("StudiquoOpenFriendAttachment"))) { notification in
            guard let request = notification.object as? FriendAttachmentOpenRequest else { return }
            openFriendAttachment(request.attachment)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("StudiquoOpenTextDocumentTab"))) { notification in
            guard let document = notification.object as? TextDocument else { return }
            openTextDocument(document)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("StudiquoOpenSlideDeckTab"))) { notification in
            guard let deck = notification.object as? SlideDeck else { return }
            openSlideDeck(deck)
        }
        .onAppear {
            if selectedNotebook == nil { columnVisibility = .detailOnly }
            refreshStudyNotifications()
        }
        .onChange(of: calendarEvents.count) { _, _ in refreshStudyNotifications() }
        .onChange(of: studyActivities.count) { _, _ in refreshStudyNotifications() }
        .task {
            await rebuildLibraryMetadataIfNeeded()
        }
        .onAppear {
            StudyTimeTracker.shared.configure(context: modelContext)
            StudyTimeTracker.shared.handle(scenePhase: scenePhase)
            StudyTimeTracker.shared.setStudying(isStudySurfaceOpen)
        }
        .onChange(of: scenePhase) { _, phase in
            StudyTimeTracker.shared.handle(scenePhase: phase)
        }
        // Count study time only while an actual study surface is open — not
        // while browsing the library or the calendar.
        .onChange(of: studySurfaceKey) { _, _ in
            StudyTimeTracker.shared.setStudying(isStudySurfaceOpen)
        }
        .onChange(of: homeSection) { _, section in
            // Calendar and friends are independent home destinations. Clear
            // every editor selection so the notebook split view can never
            // leak its sidebar into either screen.
            if section == .calendar || section == .friends {
                returnToHome()
            }
        }
        .onOpenURL { url in
            friendStore.add(url: url)
            returnToHome()
            homeSection = .friends
        }
    }

    private var homeDashboard: some View {
        VStack(spacing: 0) {
            if homeSection == .notes {
                fullScreenHome
            } else if homeSection == .calendar {
                CalendarHomeView(
                    showsNotifications: $showsNotifications,
                    notificationPanel: { AnyView(notificationPanel) }
                )
            } else {
                FriendsHomeView(
                    store: friendStore,
                    myStudySeconds: studyActivities
                        .filter { Calendar.current.isDateInToday($0.startedAt) }
                        .reduce(0) { $0 + $1.duration },
                    appAttachments: friendMessageAttachmentOptions()
                )
            }
            Divider()
            HStack(spacing: 12) {
                ForEach(HomeSection.allCases) { section in
                    Button {
                        homeSection = section
                    } label: {
                        Label(section.title, systemImage: section.icon)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(homeSection == section ? Color.white : Color.secondary)
                            .background(
                                homeSection == section ? Color.accentColor : Color.clear,
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                            // The whole pill responds, not just the label glyphs —
                            // an unselected tab's background is clear and would
                            // otherwise ignore taps on its empty area.
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(.bar)
        }
        // Calendar and friends live outside the split view entirely; notes
        // remains the only home section that can own a library sidebar.
    }

    private var notebookTabBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(openNotebooks.filter { !$0.isTrashed }) { notebook in
                    HStack(spacing: 5) {
                        Button {
                            selectNotebookTab(notebook)
                        } label: {
                            Label(notebook.title, systemImage: notebookTabIcon(for: notebook))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        Button {
                            closeTab(notebook)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(selectedNotebook === notebook ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .draggable("notebook:\(notebookID(notebook))")
                }
                ForEach(openStudyNotebooks.filter { !$0.isTrashed }) { notebook in
                    HStack(spacing: 5) {
                        Button {
                            studyNotebook = notebook
                        } label: {
                            Label("\(notebook.title)・暗記カード", systemImage: "rectangle.on.rectangle.angled")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        Button {
                            openStudyNotebooks.removeAll { $0 === notebook }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .draggable("flashcards:\(notebookID(notebook))")
                }
                ForEach(openFlashcardDecks) { deck in
                    HStack(spacing: 5) {
                        Button { selectFlashcardTab(deck) } label: {
                            Label(deck.title, systemImage: "rectangle.on.rectangle.angled").lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        Button { closeFlashcardTab(deck) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(selectedFlashcardDeck === deck ? Color.indigo.opacity(0.22) : Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .draggable("deck:\(deckID(deck))")
                }
                ForEach(openWebTabs) { tab in
                    HStack(spacing: 5) {
                        Button { selectWebTab(tab) } label: {
                            Label(tab.title, systemImage: "globe").lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        Button { openWebTabs.removeAll { $0.id == tab.id } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(Color.teal.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    .draggable("web:\(tab.title)|\(tab.homeURL)")
                }

                ForEach(openTextDocuments.filter { !$0.isTrashed }) { document in
                    HStack(spacing: 5) {
                        Button { openTextDocument(document) } label: {
                            Label(document.title, systemImage: "doc.text").lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        Button {
                            openTextDocuments.removeAll { $0 === document }
                            if selectedTextDocument === document {
                                selectedTextDocument = openTextDocuments.last
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(
                        selectedTextDocument === document ? Color.teal.opacity(0.22) : Color.teal.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .draggable("document:\(textDocumentID(document))")
                }
                ForEach(openSlideDecks.filter { !$0.isTrashed }) { deck in
                    HStack(spacing: 5) {
                        Button { openSlideDeck(deck) } label: {
                            Label(deck.title, systemImage: "rectangle.on.rectangle").lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        Button {
                            openSlideDecks.removeAll { $0 === deck }
                            if selectedSlideDeck === deck {
                                selectedSlideDeck = openSlideDecks.last
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(
                        selectedSlideDeck === deck ? Color.orange.opacity(0.24) : Color.orange.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .draggable("slide:\(slideDeckID(deck))")
                }

                ForEach(openAIChatTabs) { tab in
                    HStack(spacing: 5) {
                        Button {
                            selectAIChatTab(tab)
                        } label: {
                            Label(tab.title, systemImage: "sparkles").lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        Button { closeAIChatTab(tab.id) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(
                        selectedAIChatTabID == tab.id ? Color.purple.opacity(0.22) : Color.purple.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .draggable("ai:\(String(describing: tab.id))")
                }

                // Replaces the old sidebar toggle in the editor's tool strip:
                // opening a second note is a tab operation, so the control
                // for it belongs on the tab bar.
                Button {
                    showsTabPicker = true
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新しいタブを追加")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }

    /// While an editor is already open, every tab tap routes into whichever
    /// split pane the user didn't last touch instead of tearing the editor
    /// down and rebuilding it (which `selectedNotebook`'s `.id()` would do,
    /// discarding any active split). Only the very first tab tap — opening
    /// an editor from the home screen — still goes through `selectedNotebook`.
    /// Drops a conversation's tab. The conversation itself is untouched — it
    /// stays in the chat's history sidebar, the same way closing a notebook
    /// tab leaves the notebook on the home screen.
    private func closeAIChatTab(_ id: PersistentIdentifier) {
        openAIChatTabs.removeAll { $0.id == id }
        if selectedAIChatTabID == id { selectedAIChatTabID = openAIChatTabs.last?.id }
    }

    private func selectNotebookTab(_ notebook: Notebook) {
        openNotebookTab(notebook)
        // With no split on screen there is only one pane, so just swap the
        // selected notebook — that rebuilds the editor and is the reliable
        // path. Routing through the pane-switch notification is reserved for
        // split mode, where rebuilding would discard the other pane.
        guard editorSplitState.isSplit, selectedNotebook != nil else {
            clearOpenSelection()
            selectedNotebook = notebook
            return
        }
        NotificationCenter.default.post(
            name: Notification.Name("StudiquoSwitchPaneTarget"),
            object: PaneSwitchTarget.notebook(notebook)
        )
    }

    private func openNotebookTab(_ notebook: Notebook) {
        if !openNotebooks.contains(where: { $0.persistentModelID == notebook.persistentModelID }) {
            openNotebooks.append(notebook)
        }
    }

    private func notebookTabIcon(for notebook: Notebook) -> String {
        if notebook.isLocked { return "lock.fill" }
        if notebook.containsPDF { return "doc.richtext" }
        return "note.text"
    }

    private func selectFlashcardTab(_ deck: FlashcardDeck) {
        openFlashcardDeckTab(deck)
        guard editorSplitState.isSplit, selectedNotebook != nil else {
            clearOpenSelection()
            selectedFlashcardDeck = deck
            return
        }
        NotificationCenter.default.post(
            name: Notification.Name("StudiquoSwitchPaneTarget"),
            object: PaneSwitchTarget.flashcardDeck(deck)
        )
    }

    private func openFlashcardDeckTab(_ deck: FlashcardDeck) {
        if !openFlashcardDecks.contains(where: { $0.persistentModelID == deck.persistentModelID }) {
            openFlashcardDecks.append(deck)
        }
    }

    private func selectWebTab(_ tab: WebTabInfo) {
        guard selectedNotebook != nil else { return }
        NotificationCenter.default.post(
            name: Notification.Name("StudiquoSwitchPaneTarget"),
            object: PaneSwitchTarget.web(title: tab.title, homeURL: tab.homeURL)
        )
    }

    private func selectAIChatTab(_ tab: AIChatTabInfo) {
        selectedAIChatTabID = tab.id
        guard selectedNotebook != nil else {
            NotificationCenter.default.post(
                name: .studiquoSelectAIChatTab,
                object: tab.id
            )
            return
        }
        NotificationCenter.default.post(
            name: Notification.Name("StudiquoSwitchPaneTarget"),
            object: PaneSwitchTarget.ai(tab.id)
        )
    }

    private func closeTab(_ notebook: Notebook) {
        guard let index = openNotebooks.firstIndex(where: { $0 === notebook }) else { return }
        let wasSelected = selectedNotebook === notebook
        openNotebooks.remove(at: index)
        if wasSelected {
            selectedNotebook = openNotebooks.indices.contains(index) ? openNotebooks[index] : openNotebooks.last
        }
    }

    private func openFlashcardDeck(_ deck: FlashcardDeck) {
        clearOpenSelection()
        openFlashcardDeckTab(deck)
        selectedFlashcardDeck = deck
    }

    private func openTextDocument(_ document: TextDocument) {
        clearOpenSelection()
        selectedTextDocument = document
        if !openTextDocuments.contains(where: { $0.persistentModelID == document.persistentModelID }) {
            openTextDocuments.append(document)
        }
        columnVisibility = .detailOnly
    }

    private func openSlideDeck(_ deck: SlideDeck) {
        clearOpenSelection()
        selectedSlideDeck = deck
        if !openSlideDecks.contains(where: { $0.persistentModelID == deck.persistentModelID }) {
            openSlideDecks.append(deck)
        }
        columnVisibility = .detailOnly
    }

    /// The detail pane shows exactly one thing, so opening any of the four
    /// kinds has to clear the other three.
    private func clearOpenSelection() {
        selectedNotebook = nil
        selectedFlashcardDeck = nil
        selectedTextDocument = nil
        selectedSlideDeck = nil
    }

    private func closeFlashcardTab(_ deck: FlashcardDeck) {
        guard let index = openFlashcardDecks.firstIndex(where: { $0 === deck }) else { return }
        let wasSelected = selectedFlashcardDeck === deck
        openFlashcardDecks.remove(at: index)
        if wasSelected {
            selectedFlashcardDeck = openFlashcardDecks.indices.contains(index) ? openFlashcardDecks[index] : openFlashcardDecks.last
        }
    }

    private func returnToHome() {
        selectedNotebook = nil
        selectedFlashcardDeck = nil
        selectedTextDocument = nil
        selectedSlideDeck = nil
        selectedFolder = nil
        libraryMode = .documents
        searchText = ""
        columnVisibility = .detailOnly
    }

    private func notebookID(_ notebook: Notebook) -> String {
        String(describing: notebook.persistentModelID)
    }

    private func deckID(_ deck: FlashcardDeck) -> String {
        String(describing: deck.persistentModelID)
    }

    private func textDocumentID(_ document: TextDocument) -> String {
        String(describing: document.persistentModelID)
    }

    private func slideDeckID(_ deck: SlideDeck) -> String {
        String(describing: deck.persistentModelID)
    }

    private func openFriendAttachment(_ attachment: FriendMessageAttachment) {
        if let sourcePath = attachment.sourcePath, !sourcePath.isEmpty {
            let url = URL(filePath: sourcePath)
            if FileManager.default.fileExists(atPath: url.path) {
                previewURL = IdentifiableURL(url: url)
                return
            }
        }
        guard let sourceKind = attachment.resolvedSourceKind,
              let sourceID = attachment.resolvedSourceID else { return }
        switch sourceKind {
        case "notebook":
            guard let notebook = allNotebooks.first(where: { notebookID($0) == sourceID && !$0.isTrashed }) else { return }
            selectNotebookTab(notebook)
        case "deck", "flashcards":
            guard let deck = flashcardDecks.first(where: { deckID($0) == sourceID && !$0.isTrashed }) else { return }
            selectFlashcardTab(deck)
        case "document":
            guard let document = textDocuments.first(where: { textDocumentID($0) == sourceID && !$0.isTrashed }) else { return }
            openTextDocument(document)
        case "slide":
            guard let deck = slideDecks.first(where: { slideDeckID($0) == sourceID && !$0.isTrashed }) else { return }
            openSlideDeck(deck)
        case "photo", "pdf", "file":
            // No local copy on this device (e.g. this is the recipient, who
            // never had the file locally) — fetch it from the room.
            guard let roomID = attachment.remoteRoomID else { return }
            downloadAndPreviewFriendAttachment(sourceKind: sourceKind, sourceID: sourceID, roomID: roomID, title: attachment.title)
        default:
            return
        }
    }

    private func downloadAndPreviewFriendAttachment(sourceKind: String, sourceID: String, roomID: String, title: String) {
        isDownloadingFriendAttachment = true
        Task {
            guard let data = await friendStore.downloadAttachment(roomID: roomID, id: sourceID) else {
                await MainActor.run {
                    isDownloadingFriendAttachment = false
                    friendStore.errorMessage = "添付ファイルを読み込めませんでした。"
                }
                return
            }
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "FriendChatAttachments", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext: String
            if sourceKind == "photo" {
                ext = "jpg"
            } else {
                let titleExtension = (title as NSString).pathExtension
                ext = titleExtension.isEmpty ? (sourceKind == "pdf" ? "pdf" : "dat") : titleExtension
            }
            let destination = directory.appending(path: "\(sourceID).\(ext)")
            if !FileManager.default.fileExists(atPath: destination.path) {
                guard (try? data.write(to: destination, options: [.atomic])) != nil else {
                    await MainActor.run {
                        isDownloadingFriendAttachment = false
                        friendStore.errorMessage = "添付ファイルを読み込めませんでした。"
                    }
                    return
                }
            }
            await MainActor.run {
                isDownloadingFriendAttachment = false
                previewURL = IdentifiableURL(url: destination)
            }
        }
    }

    private func friendMessageAttachmentOptions() -> [FriendMessageAttachment] {
        var options: [FriendMessageAttachment] = []
        options.append(contentsOf: allNotebooks.filter { !$0.isTrashed }.map {
            FriendMessageAttachment(
                id: "notebook-\(String(describing: $0.persistentModelID))",
                title: $0.title,
                kind: $0.containsPDF ? "PDF" : "ノート",
                icon: $0.containsPDF ? "doc.richtext" : "note.text",
                sourceKind: "notebook",
                sourceID: String(describing: $0.persistentModelID)
            )
        })
        options.append(contentsOf: flashcardDecks.filter { !$0.isTrashed }.map {
            FriendMessageAttachment(
                id: "deck-\(String(describing: $0.persistentModelID))",
                title: $0.title,
                kind: "暗記カード",
                icon: "rectangle.on.rectangle.angled",
                sourceKind: "deck",
                sourceID: String(describing: $0.persistentModelID)
            )
        })
        options.append(contentsOf: textDocuments.filter { !$0.isTrashed }.map {
            FriendMessageAttachment(
                id: "document-\(String(describing: $0.persistentModelID))",
                title: $0.title,
                kind: "文書",
                icon: "doc.text",
                sourceKind: "document",
                sourceID: String(describing: $0.persistentModelID)
            )
        })
        options.append(contentsOf: slideDecks.filter { !$0.isTrashed }.map {
            FriendMessageAttachment(
                id: "slide-\(String(describing: $0.persistentModelID))",
                title: $0.title,
                kind: "スライド",
                icon: "rectangle.on.rectangle",
                sourceKind: "slide",
                sourceID: String(describing: $0.persistentModelID)
            )
        })
        return options
    }

    private func handleTabDrop(_ value: String) -> Bool {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        if parts[0] == "deck", let deck = flashcardDecks.first(where: { deckID($0) == parts[1] }) {
            selectedNotebook = nil
            openFlashcardDeckTab(deck)
            selectedFlashcardDeck = deck
            return true
        }
        guard let notebook = allNotebooks.first(where: { notebookID($0) == parts[1] && !$0.isTrashed }) else { return false }
        if parts[0] == "flashcards" {
            studyNotebook = notebook
        } else {
            selectedFlashcardDeck = nil
            openNotebookTab(notebook)
            selectedNotebook = notebook
        }
        return true
    }

    private func handleFolderDrop(_ values: [String], into folder: String) -> Bool {
        var didMove = false
        for value in values {
            let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "notebook":
                guard let notebook = allNotebooks.first(where: { notebookID($0) == parts[1] && !$0.isTrashed }) else { continue }
                notebook.folderName = folder
                notebook.updatedAt = .now
                didMove = true
            case "deck":
                guard let deck = flashcardDecks.first(where: { deckID($0) == parts[1] }) else { continue }
                deck.folderName = folder
                deck.updatedAt = .now
                didMove = true
            case "document":
                guard let document = textDocuments.first(where: { textDocumentID($0) == parts[1] && !$0.isTrashed }) else { continue }
                document.folderName = folder
                document.updatedAt = .now
                didMove = true
            case "slide":
                guard let deck = slideDecks.first(where: { slideDeckID($0) == parts[1] && !$0.isTrashed }) else { continue }
                deck.folderName = folder
                deck.updatedAt = .now
                didMove = true
            default:
                continue
            }
        }
        if didMove {
            expandedSidebarFolders.insert(folder)
            try? modelContext.save()
        }
        return didMove
    }

    private func notebooksInFolder(_ folder: String) -> [Notebook] {
        allNotebooks
            .filter { !$0.isTrashed && $0.folderName == folder }
            .sorted(by: sortOption.comparator)
    }

    private func decksInFolder(_ folder: String) -> [FlashcardDeck] {
        flashcardDecks
            .filter { $0.folderName == folder }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func textDocumentsInFolder(_ folder: String) -> [TextDocument] {
        textDocuments
            .filter { !$0.isTrashed && $0.folderName == folder }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func slideDecksInFolder(_ folder: String) -> [SlideDeck] {
        slideDecks
            .filter { !$0.isTrashed && $0.folderName == folder }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func sidebarFolderBinding(_ folder: String) -> Binding<Bool> {
        Binding(
            get: { expandedSidebarFolders.contains(folder) },
            set: { isExpanded in
                if isExpanded { expandedSidebarFolders.insert(folder) }
                else { expandedSidebarFolders.remove(folder) }
            }
        )
    }

    private func sidebarFolderRow(_ folder: String) -> some View {
        DisclosureGroup(
            isExpanded: sidebarFolderBinding(folder),
            content: {
                ForEach(notebooksInFolder(folder)) { notebook in
                    sidebarNotebookButton(notebook)
                }
                ForEach(decksInFolder(folder)) { deck in
                    sidebarFlashcardDeckButton(deck)
                }
                ForEach(textDocumentsInFolder(folder)) { document in
                    sidebarTextDocumentButton(document)
                }
                ForEach(slideDecksInFolder(folder)) { deck in
                    sidebarSlideDeckButton(deck)
                }
            },
            label: {
                HStack {
                    Label(folder, systemImage: "folder.fill")
                    Spacer()
                    folderDropBadge(folder)
                }
            }
        )
        .dropDestination(
            for: String.self,
            action: { items, _ in
                handleFolderDrop(items, into: folder)
            },
            isTargeted: { isTargeted in
                folderDropTarget = isTargeted ? folder : (folderDropTarget == folder ? nil : folderDropTarget)
            }
        )
    }

    private func folderRow(
        _ folder: String,
        notebookCount: Int,
        deckCount: Int,
        documentCount: Int,
        slideCount: Int
    ) -> some View {
        HStack(spacing: 10) {
            Button {
                selectedFolder = folder
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(folderDisplayName(folder)).font(.headline)
                        Text("\(notebookCount)冊のノート・\(deckCount)個の暗記帳・\(documentCount)個の文書・\(slideCount)個のスライド")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    folderDropBadge(folder)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { toggleFolderFavorite(folder) } label: {
                Image(systemName: favoriteFolderPaths.contains(folder) ? "star.fill" : "star")
                    .foregroundStyle(favoriteFolderPaths.contains(folder) ? .yellow : .secondary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .dropDestination(
            for: String.self,
            action: { items, _ in
                handleFolderDrop(items, into: folder)
            },
            isTargeted: { isTargeted in
                folderDropTarget = isTargeted ? folder : (folderDropTarget == folder ? nil : folderDropTarget)
            }
        )
    }

    private func folderDropBadge(_ folder: String) -> some View {
        Image(systemName: "plus.circle.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.green)
            .opacity(folderDropTarget == folder ? 1 : 0)
            .scaleEffect(folderDropTarget == folder ? 1 : 0.6)
            .animation(.easeOut(duration: 0.12), value: folderDropTarget)
    }

    private func sidebarNotebookButton(_ notebook: Notebook) -> some View {
        Button {
            clearOpenSelection()
            selectedNotebook = notebook
            columnVisibility = .detailOnly
        } label: {
            HStack(spacing: 8) {
                Image(systemName: notebook.containsPDF ? "doc.richtext" : "note.text")
                    .foregroundStyle(notebook.containsPDF ? .red : .blue)
                Text(notebook.title)
                    .lineLimit(1)
                Spacer()
                if selectedNotebook === notebook {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .draggable("notebook:\(notebookID(notebook))")
    }

    private func sidebarFlashcardDeckButton(_ deck: FlashcardDeck) -> some View {
        Button {
            openFlashcardDeck(deck)
            columnVisibility = .detailOnly
        } label: {
            Label(deck.title, systemImage: "rectangle.on.rectangle.angled")
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .draggable("deck:\(deckID(deck))")
    }

    private func sidebarTextDocumentButton(_ document: TextDocument) -> some View {
        Button {
            openTextDocument(document)
            columnVisibility = .detailOnly
        } label: {
            Label(document.title, systemImage: "doc.text")
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .draggable("document:\(textDocumentID(document))")
    }

    private func sidebarSlideDeckButton(_ deck: SlideDeck) -> some View {
        Button {
            openSlideDeck(deck)
            columnVisibility = .detailOnly
        } label: {
            Label(deck.title, systemImage: "rectangle.on.rectangle")
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .draggable("slide:\(slideDeckID(deck))")
    }

    private var fullScreenHome: some View {
        let notebookCounts = Dictionary(
            grouping: allNotebooks.filter { !$0.isTrashed },
            by: \.folderName
        ).mapValues(\.count)
        let deckCounts = Dictionary(grouping: flashcardDecks, by: \.folderName).mapValues(\.count)
        let documentCounts = Dictionary(grouping: textDocuments.filter { !$0.isTrashed }, by: \.folderName).mapValues(\.count)
        let slideCounts = Dictionary(grouping: slideDecks.filter { !$0.isTrashed }, by: \.folderName).mapValues(\.count)

        return List(selection: $selectedNotebook) {
            if libraryMode == .documents {
                Section {
                    ForEach(visibleFolderPaths, id: \.self) { folder in
                        folderRow(
                            folder,
                            notebookCount: notebookCounts[folder, default: 0],
                            deckCount: deckCounts[folder, default: 0],
                            documentCount: documentCounts[folder, default: 0],
                            slideCount: slideCounts[folder, default: 0]
                        )
                    }
                    let displayedNotebooks = selectedFolder == nil ? homeNotebooks : visibleNotebooks
                    notebookRows(displayedNotebooks)
                    studyCardRows
                    documentRows
                    slideRows
                }
            } else if libraryMode == .studyCards && selectedFolder == nil {
                studyCardRows
            } else if libraryMode == .textDocuments && selectedFolder == nil {
                documentRows
            } else if libraryMode == .slides && selectedFolder == nil {
                slideRows
            } else if libraryMode == .favorites && selectedFolder == nil {
                favoriteRows
            } else {
                notebookRows(visibleNotebooks)
                if libraryMode == .trash && selectedFolder == nil {
                    trashedItemRows
                }
            }
        }
        .navigationTitle(selectedFolder.map(folderDisplayName) ?? (isHomeScreen ? L("ホーム") : libraryMode.title))
        .searchable(text: $searchText, prompt: "ノートを検索")
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                colors: [Color(red: 0.94, green: 0.97, blue: 1.0), Color(red: 0.98, green: 0.95, blue: 0.91)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                HStack {
                    if selectedFolder != nil {
                        Button {
                            goBackOneFolder()
                        } label: {
                            Label("一つ前のフォルダへ戻る", systemImage: "chevron.left")
                        }
                        Button {
                            selectedFolder = nil
                            libraryMode = .documents
                        } label: {
                            Label("ホームへ戻る", systemImage: "house.fill")
                        }
                    }
                    Menu {
                        Picker("並べ替え", selection: $sortOption) {
                            ForEach(NotebookSortOption.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        Label("並べ替え", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    if isHomeScreen {
                        notificationBell
                    }
                    if libraryMode == .studyCards && selectedFolder == nil {
                        Button {
                            isShowingNewFlashcardDeckAlert = true
                        } label: {
                            Label("新規暗記カードを作成", systemImage: "plus")
                        }
                    } else if libraryMode == .trash && selectedFolder == nil {
                        Button("空にする", role: .destructive) {
                            showsEmptyTrashConfirmation = true
                        }
                        .disabled(isTrashEmpty)
                    } else {
                        createMenu
                    }
                    Button { showsAppSettings = true } label: {
                        Label("設定", systemImage: "gearshape")
                    }
                    .accessibilityLabel("設定")
                    Button { showsProfile = true } label: {
                        if let image = UIImage(data: profileImageData) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 28, height: 28)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(.secondary.opacity(0.35), lineWidth: 0.5))
                        } else {
                            Image(systemName: "person.crop.circle")
                                .font(.title3)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("プロフィール")
                }
            }
        }
        .confirmationDialog("ゴミ箱を空にしますか？", isPresented: $showsEmptyTrashConfirmation, titleVisibility: .visible) {
            Button("完全に削除", role: .destructive) { emptyTrash() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は取り消せません。")
        }
        .overlay {
            if libraryMode == .studyCards && selectedFolder == nil && flashcardDecks.isEmpty {
                ContentUnavailableView(
                    "暗記カードがありません",
                    systemImage: "rectangle.on.rectangle.angled",
                    description: Text("右上の＋から新しい暗記帳を作成してください")
                )
            } else if isHomeScreen
                        && searchText.isEmpty
                        && visibleNotebooks.isEmpty
                        && displayedFlashcardDecks.isEmpty
                        && displayedTextDocuments.isEmpty
                        && displayedSlideDecks.isEmpty {
                // The home screen used to show nothing at all when empty.
                ContentUnavailableView {
                    Label("まだ何もありません", systemImage: "square.and.pencil")
                } description: {
                    Text("右上の＋から、ノート・暗記帳・文書・スライドを作成できます。")
                }
            } else if selectedFolder == nil
                        && !isHomeScreen
                        && visibleNotebooks.isEmpty
                        && displayedFlashcardDecks.isEmpty
                        && displayedTextDocuments.isEmpty
                        && displayedSlideDecks.isEmpty
                        && !(libraryMode == .favorites && hasFavoriteNonNotebookItems)
                        && !(libraryMode == .trash && !isTrashEmpty) {
                ContentUnavailableView(
                    searchText.isEmpty ? (selectedFolder == nil ? libraryMode.emptyTitle : "このフォルダは空です") : "見つかりません",
                    systemImage: searchText.isEmpty ? (selectedFolder == nil ? libraryMode.icon : "folder") : "magnifyingglass",
                    description: Text(searchText.isEmpty ? (selectedFolder == nil ? libraryMode.emptyMessage : "このフォルダにはまだノートや暗記帳がありません。") : "別の言葉で検索してください")
                )
            }
        }
    }

    private var notificationPanel: some View {
        StudyNotificationList(
            notifications: cachedStudyNotifications,
            readIDs: readStudyNotificationIDs,
            onSelect: openNotification,
            onMarkAllRead: markAllNotificationsRead,
            onMarkRead: markNotificationRead,
            onOpenSettings: {
                showsNotifications = false
                showsAppSettings = true
            }
        )
    }

    private var notificationBell: some View {
        Button { showsNotifications = true } label: {
            Image(systemName: unreadStudyNotificationCount > 0 ? "bell.fill" : "bell")
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
                .overlay(alignment: .topTrailing) {
                    if unreadStudyNotificationCount > 0 {
                        Text("\(min(unreadStudyNotificationCount, 9))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(.red, in: Circle())
                            .offset(x: 6, y: -2)
                    }
                }
        }
        .accessibilityLabel("通知")
        .accessibilityValue(unreadStudyNotificationCount == 0 ? L("未読なし") : L("未読\(unreadStudyNotificationCount)件"))
        .popover(isPresented: $showsNotifications, arrowEdge: .top) {
            notificationPanel
        }
    }

    private func markAllNotificationsRead() {
        readStudyNotificationIDsStorage = cachedStudyNotifications.map(\.id).joined(separator: "\n")
    }

    /// Opening a notification's body marks it read without closing the list,
    /// so the next one is still one back-swipe away.
    private func markNotificationRead(_ notification: StudyNotification) {
        var ids = readStudyNotificationIDs
        guard !ids.contains(notification.id) else { return }
        ids.insert(notification.id)
        readStudyNotificationIDsStorage = ids.joined(separator: "\n")
    }

    private func openNotification(_ notification: StudyNotification) {
        var ids = readStudyNotificationIDs
        ids.insert(notification.id)
        readStudyNotificationIDsStorage = ids.joined(separator: "\n")
        showsNotifications = false
        if notification.destination == .calendar {
            homeSection = .calendar
        }
    }

    private func refreshStudyNotifications() {
        cachedStudyNotifications = makeStudyNotifications()
    }

    private var studyCardCount: Int {
        flashcardDecks.reduce(0) { $0 + $1.sortedCards.count }
    }

    private var displayedFlashcardDecks: [FlashcardDeck] {
        let visible = flashcardDecks.filter { !$0.isTrashed }
        if libraryMode == .documents {
            return visible.filter { $0.folderName == (selectedFolder ?? "") }
        }
        return visible
    }

    @ViewBuilder
    private var studyCardRows: some View {
        ForEach(displayedFlashcardDecks) { deck in
            HStack(spacing: 10) {
                Button { openFlashcardDeck(deck) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.title2)
                            .foregroundStyle(.indigo)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(deck.title).font(.headline).lineLimit(1)
                            Text("\(deck.sortedCards.count)枚 ・ 学習\(deck.studySessionCount)回 ・ 正解率\(deck.accuracyText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { deck.isFavorite.toggle(); deck.updatedAt = .now } label: {
                    Image(systemName: deck.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(deck.isFavorite ? .yellow : .secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }
            .swipeActions {
                Button("ゴミ箱", role: .destructive) { trashDeck(deck) }
            }
            .draggable("deck:\(deckID(deck))")
        }
    }

    private var displayedTextDocuments: [TextDocument] {
        let visible = textDocuments.filter { !$0.isTrashed }
        if libraryMode == .documents {
            return visible.filter { $0.folderName == (selectedFolder ?? "") }
        }
        return visible
    }

    private var displayedSlideDecks: [SlideDeck] {
        let visible = slideDecks.filter { !$0.isTrashed }
        if libraryMode == .documents {
            return visible.filter { $0.folderName == (selectedFolder ?? "") }
        }
        return visible
    }

    @ViewBuilder
    private var documentRows: some View {
        ForEach(displayedTextDocuments) { document in
            HStack(spacing: 10) {
                Button { openTextDocument(document) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.title2)
                            .foregroundStyle(.teal)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(document.title).font(.headline).lineLimit(1)
                            Text("\(document.wordCount)語 ・ \(document.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { document.isFavorite.toggle(); document.updatedAt = .now } label: {
                    Image(systemName: document.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(document.isFavorite ? .yellow : .secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }
            .swipeActions {
                Button("ゴミ箱", role: .destructive) { trashDocument(document) }
            }
            .draggable("document:\(textDocumentID(document))")
        }
    }

    @ViewBuilder
    private var slideRows: some View {
        ForEach(displayedSlideDecks) { deck in
            HStack(spacing: 10) {
                Button { openSlideDeck(deck) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(deck.title).font(.headline).lineLimit(1)
                            Text("\(deck.sortedSlides.count)枚 ・ \(deck.theme.title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { deck.isFavorite.toggle(); deck.updatedAt = .now } label: {
                    Image(systemName: deck.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(deck.isFavorite ? .yellow : .secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }
            .swipeActions {
                Button("ゴミ箱", role: .destructive) { trashSlideDeck(deck) }
            }
            .draggable("slide:\(slideDeckID(deck))")
        }
    }

    /// Trashed decks, documents and slides — shown in the trash alongside
    /// trashed notes, each restorable or removable for good.
    @ViewBuilder
    private var trashedItemRows: some View {
        let decks = flashcardDecks.filter { $0.isTrashed }
        let documents = textDocuments.filter { $0.isTrashed }
        let slides = slideDecks.filter { $0.isTrashed }
        ForEach(decks) { deck in
            trashedRow(title: deck.title, subtitle: "\(deck.sortedCards.count)枚の暗記カード",
                       icon: "rectangle.on.rectangle.angled", tint: .indigo,
                       restore: { restoreDeck(deck) }, delete: { permanentlyDeleteDeck(deck) })
        }
        ForEach(documents) { document in
            trashedRow(title: document.title, subtitle: "\(document.wordCount)語の文書",
                       icon: "doc.text", tint: .teal,
                       restore: { restoreDocument(document) }, delete: { permanentlyDeleteDocument(document) })
        }
        ForEach(slides) { deck in
            trashedRow(title: deck.title, subtitle: "\(deck.sortedSlides.count)枚のスライド",
                       icon: "rectangle.on.rectangle", tint: .orange,
                       restore: { restoreSlideDeck(deck) }, delete: { permanentlyDeleteSlideDeck(deck) })
        }
    }

    private func trashedRow(title: String, subtitle: String, icon: String, tint: Color,
                            restore: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .leading) {
            Button { restore() } label: { Label("復元", systemImage: "arrow.uturn.backward") }
                .tint(.blue)
        }
        .swipeActions {
            Button("完全に削除", role: .destructive, action: delete)
        }
    }

    private func restoreDeck(_ deck: FlashcardDeck) { deck.isTrashed = false; deck.trashedAt = nil }
    private func restoreDocument(_ document: TextDocument) { document.isTrashed = false; document.trashedAt = nil }
    private func restoreSlideDeck(_ deck: SlideDeck) { deck.isTrashed = false; deck.trashedAt = nil }

    private func permanentlyDeleteDeck(_ deck: FlashcardDeck) { closeDeckTabs(deck); modelContext.delete(deck) }
    private func permanentlyDeleteDocument(_ document: TextDocument) { closeDocumentTabs(document); modelContext.delete(document) }
    private func permanentlyDeleteSlideDeck(_ deck: SlideDeck) { closeSlideDeckTabs(deck); modelContext.delete(deck) }

    private var hasFavoriteNonNotebookItems: Bool {
        !favoriteFolderPaths.isEmpty
            || flashcardDecks.contains { !$0.isTrashed && $0.isFavorite }
            || textDocuments.contains { !$0.isTrashed && $0.isFavorite }
            || slideDecks.contains { !$0.isTrashed && $0.isFavorite }
    }

    @ViewBuilder
    private var favoriteRows: some View {
        let folders = sortedFolderNames.filter { favoriteFolderPaths.contains($0) }
        if !folders.isEmpty {
            Section("フォルダ") {
                ForEach(folders, id: \.self) { folder in
                    HStack {
                        Button {
                            selectedFolder = folder
                            libraryMode = .documents
                        } label: {
                            Label(folderDisplayName(folder), systemImage: "folder.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { toggleFolderFavorite(folder) } label: {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        if !visibleNotebooks.isEmpty {
            Section("ノート・PDF") { notebookRows(visibleNotebooks) }
        }
        let decks = flashcardDecks.filter(\.isFavorite)
        if !decks.isEmpty {
            Section("暗記帳") {
                ForEach(decks) { deck in
                    HStack {
                        Button { openFlashcardDeck(deck) } label: {
                            Label(deck.title, systemImage: "rectangle.on.rectangle.angled")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { deck.isFavorite = false } label: {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func toggleFolderFavorite(_ folder: String) {
        var favorites = favoriteFolderPaths
        if favorites.contains(folder) { favorites.remove(folder) }
        else { favorites.insert(folder) }
        favoriteFolderPathsStorage = favorites.sorted().joined(separator: "\n")
    }

    private func createTextDocument() {
        let title = newDocumentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let document = TextDocument(title: title.isEmpty ? L("無題の文書") : title)
        document.folderName = selectedFolder ?? ""
        modelContext.insert(document)
        try? modelContext.save()
        newDocumentName = ""
        openTextDocument(document)
    }

    private func createSlideDeck() {
        let title = newSlideDeckName.trimmingCharacters(in: .whitespacesAndNewlines)
        let deck = SlideDeck(title: title.isEmpty ? L("無題のスライド") : title)
        deck.folderName = selectedFolder ?? ""
        modelContext.insert(deck)
        try? modelContext.save()
        newSlideDeckName = ""
        openSlideDeck(deck)
    }

    private func createFlashcardDeck() {
        let title = newFlashcardDeckName.trimmingCharacters(in: .whitespacesAndNewlines)
        let deck = FlashcardDeck(title: title.isEmpty ? "新しい暗記帳" : title)
        deck.folderName = selectedFolder ?? ""
        modelContext.insert(deck)
        newFlashcardDeckName = ""
        openFlashcardDeck(deck)
    }

    private var createMenu: some View {
        Menu {
            Button {
                isShowingNewNotebookAlert = true
            } label: {
                Label("新規ノート", systemImage: "square.and.pencil")
            }
            Button {
                isShowingNewFolderAlert = true
            } label: {
                Label("新規フォルダ", systemImage: "folder.badge.plus")
            }
            Button {
                isShowingNewFlashcardDeckAlert = true
            } label: {
                Label("新規暗記カードを作成", systemImage: "rectangle.on.rectangle.angled")
            }
            Button {
                isShowingNewDocumentAlert = true
            } label: {
                Label("新規文書", systemImage: "doc.text")
            }
            Button {
                isShowingNewSlideDeckAlert = true
            } label: {
                Label("新規スライド", systemImage: "rectangle.on.rectangle")
            }
            Button {
                presentFileImporter()
            } label: {
                Label("ファイルから読み込む", systemImage: "folder.badge.plus")
            }
            Button {
                presentFileImporter()
            } label: {
                Label("単語帳を読み込む（Quizlet・CSV）", systemImage: "rectangle.stack.badge.plus")
            }
            Button {
                presentPDFUnlockPicker()
            } label: {
                Label("PDFのパスワードを削除", systemImage: "lock.open.rotation")
            }
            Divider()
            Button {
                backupURL = exportMCPSnapshot().map(IdentifiableURL.init(url:))
            } label: {
                Label("MCP連携データを書き出す", systemImage: "brain.head.profile")
            }
            Button {
                presentFileImporter()
            } label: {
                Label("MCPの変更を読み込む", systemImage: "tray.and.arrow.down")
            }
            Button {
                showsMCPCloudSettings = true
            } label: {
                Label("MCPクラウド連携", systemImage: "icloud")
            }
            Button {
                isImportingBackup = true
            } label: {
                Label("バックアップを復元", systemImage: "externaldrive.badge.plus")
            }
            Button {
                showsAutomaticBackups = true
            } label: {
                Label("自動バックアップを復元", systemImage: "clock.arrow.circlepath")
            }
        } label: {
            Image(systemName: "plus")
        }
    }

    @ViewBuilder
    private func notebookActions(_ notebook: Notebook) -> some View {
        if notebook.isTrashed {
            Button { restore(notebook) } label: { Label("復元", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { permanentlyDelete(notebook) } label: { Label("完全に削除", systemImage: "trash") }
        } else {
            Button { notebook.isFavorite.toggle() } label: {
                Label(notebook.isFavorite ? L("お気に入りを解除") : L("お気に入り"), systemImage: notebook.isFavorite ? "star.slash" : "star")
            }
            Button { beginRename(notebook) } label: { Label("名前を変更", systemImage: "pencil") }
            Button { beginTagEditing(notebook) } label: { Label("タグを編集", systemImage: "tag") }
            Button {
                notebook.isLocked.toggle()
                notebook.updatedAt = .now
            } label: {
                Label(notebook.isLocked ? L("保護を解除") : L("ノートを保護"), systemImage: notebook.isLocked ? "lock.open" : "lock")
            }
            Button {
                backupURL = NotebookBackupService.export(notebook).map(IdentifiableURL.init(url:))
            } label: { Label("バックアップを書き出す", systemImage: "externaldrive") }
            Menu {
                Button { notebook.folderName = "" } label: { Label("フォルダから外す", systemImage: "tray") }
                ForEach(sortedFolderNames, id: \.self) { folder in
                    Button { notebook.folderName = folder } label: {
                        if notebook.folderName == folder { Label(folder, systemImage: "checkmark") }
                        else { Text(folder) }
                    }
                }
            } label: { Label("フォルダへ移動", systemImage: "folder") }
            Button { duplicate(notebook) } label: { Label("複製", systemImage: "plus.square.on.square") }
            Divider()
            Button(role: .destructive) { moveToTrash(notebook) } label: { Label("ゴミ箱に移動", systemImage: "trash") }
        }
    }

    private func createBlankNotebook(template: PageTemplate = .blank) {
        let title = newNotebookName.trimmingCharacters(in: .whitespacesAndNewlines)
        let notebook = Notebook(title: title.isEmpty ? L("無題のノート") : title)
        let page = NotePage(order: 0)
        page.pageTemplate = template
        page.notebook = notebook
        notebook.addPage(page)
        notebook.refreshLibraryMetadata()
        notebook.folderName = selectedFolder ?? ""
        modelContext.insert(notebook)
        newNotebookName = ""
        openNotebookTab(notebook)
        selectedNotebook = notebook
        libraryMode = .documents
    }

    private func importPDF(from url: URL, password: String? = nil) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }

        // A password-protected PDF opens to blank pages unless it is unlocked
        // first. Hold it aside and ask for the password, exactly as PDF
        // Expert does when a locked file is opened.
        if password == nil, PDFPasswordService.needsPassword(url) {
            // Copy it somewhere stable first: the prompt is presented in a
            // later runloop turn, by which point the picker's own temp copy
            // may be gone.
            guard let stableURL = PDFStableCopyService.copy(url) else {
                pdfPrepareError = L("PDFの準備に失敗しました。もう一度お試しください。")
                return
            }
            pdfPasswordEntry = ""
            pdfPasswordError = nil
            pdfPendingImport = stableURL
            return
        }

        let notebook = Notebook(title: url.deletingPathExtension().lastPathComponent)
        notebook.folderName = selectedFolder ?? ""
        for (index, pageData) in PDFImportService.extractPages(from: url, password: password).enumerated() {
            let page = NotePage(order: index, backgroundImageData: pageData.imageData, pageWidth: pageData.width, pageHeight: pageData.height)
            page.recognizedText = pageData.text
            page.textRecognitionDate = .now
            page.notebook = notebook
            notebook.addPage(page)
        }
        guard !notebook.sortedPages.isEmpty else { return }
        notebook.refreshLibraryMetadata()
        modelContext.insert(notebook)
        openNotebookTab(notebook)
        selectedNotebook = notebook
        libraryMode = .documents
    }

    private var pdfPasswordPromptShown: Binding<Bool> {
        Binding(
            get: { pdfPendingImport != nil || pdfPendingUnlock != nil },
            set: { if !$0 { cancelPDFPassword() } }
        )
    }

    private var pdfRemovalOfferShown: Binding<Bool> {
        Binding(
            get: { pdfRemovalOffer != nil },
            set: { if !$0 { pdfRemovalOffer = nil } }
        )
    }

    /// The password prompt shared by both flows — importing a locked PDF, and
    /// stripping the password to save a copy. Which one is pending decides
    /// what "OK" does.
    private func submitPDFPassword() {
        let password = pdfPasswordEntry
        if let url = pdfPendingImport {
            // Verify before committing to the import so a wrong password
            // keeps the prompt up with an error rather than making a blank
            // notebook.
            do {
                _ = try PDFPasswordService.unlock(url, password: password)
            } catch {
                pdfPasswordError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return
            }
            pdfPendingImport = nil
            pdfPasswordEntry = ""
            importPDF(from: url, password: password)
            // The file is unlocked and its password is now known — offer to
            // keep a password-free copy, the way PDF Expert does once you've
            // opened a protected file. The password is held only long enough
            // to write that copy if the student says yes.
            pdfRemovalOffer = PendingRemoval(url: url, password: password)
            return
        }
        if let url = pdfPendingUnlock {
            do {
                let output = try PDFPasswordService.removePassword(
                    from: url,
                    password: password,
                    to: PDFPasswordService.destinationURL(for: url)
                )
                pdfPendingUnlock = nil
                pdfPasswordEntry = ""
                pdfUnlockedResult = IdentifiableURL(url: output)
            } catch {
                pdfPasswordError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func cancelPDFPassword() {
        pdfPendingImport = nil
        pdfPendingUnlock = nil
        pdfPasswordEntry = ""
        pdfPasswordError = nil
    }

    /// Entry point for the "PDFのパスワードを削除" menu item: takes a picked
    /// PDF and either strips it straight away (owner-restricted only) or asks
    /// for the open password first.
    private func beginPasswordRemoval(for url: URL) {
        guard let source = PDFStableCopyService.copy(url) else {
            pdfPrepareError = L("PDFの準備に失敗しました。もう一度お試しください。")
            return
        }
        switch PDFPasswordService.removalOutcome(for: source) {
        case .notProtected:
            pdfNotProtectedError = PDFPasswordService.ServiceError.notProtected.errorDescription
        case .needsPassword:
            pdfPasswordEntry = ""
            pdfPasswordError = nil
            pdfPendingUnlock = source
        case .readyToStripImmediately:
            // No open password, only owner restrictions — nothing to type.
            do {
                let output = try PDFPasswordService.removePassword(
                    from: source, password: "",
                    to: PDFPasswordService.destinationURL(for: source)
                )
                pdfUnlockedResult = IdentifiableURL(url: output)
            } catch {
                pdfPendingUnlock = source
                pdfPasswordError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func importFile(from url: URL) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        let fileExtension = url.pathExtension.lowercased()
        if fileExtension == "json", importMCPActions(from: url) {
            return
        }
        if type?.conforms(to: .pdf) == true || fileExtension == "pdf" {
            importPDF(from: url)
            return
        }
        if ["txt", "tsv", "csv"].contains(fileExtension), importFlashcards(from: url) {
            return
        }
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp"]
        guard type?.conforms(to: .image) == true || imageExtensions.contains(fileExtension),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let image = UIImage(data: data) else { return }
        let notebook = Notebook(title: url.deletingPathExtension().lastPathComponent)
        notebook.folderName = selectedFolder ?? ""
        let page = NotePage(
            order: 0,
            backgroundImageData: image.jpegData(compressionQuality: 0.9),
            pageWidth: image.size.width,
            pageHeight: image.size.height
        )
        page.notebook = notebook
        notebook.addPage(page)
        notebook.refreshLibraryMetadata()
        modelContext.insert(notebook)
        openNotebookTab(notebook)
        selectedNotebook = notebook
        libraryMode = .documents
    }

    private func exportMCPSnapshot() -> URL? {
        guard let data = makeMCPSnapshotData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("studiquo-mcp-snapshot.json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func makeMCPSnapshotData() -> Data? {
        let snapshot = MCPSnapshot(
            version: 1,
            exportedAt: .now,
            notebooks: allNotebooks.filter { !$0.isTrashed }.map { notebook in
                MCPNotebook(
                    id: String(describing: notebook.persistentModelID),
                    title: notebook.title,
                    pages: notebook.sortedPages.map { page in
                        MCPPage(
                            id: String(describing: page.persistentModelID),
                            title: page.title,
                            recognizedText: page.recognizedText
                        )
                    }
                )
            },
            flashcardDecks: flashcardDecks.map { deck in
                MCPDeck(
                    id: String(describing: deck.persistentModelID),
                    title: deck.title,
                    cards: deck.sortedCards.map { MCPCard(question: $0.question, answer: $0.answer) }
                )
            },
            studyActivities: studyActivities.map {
                MCPStudyActivity(
                    startedAt: $0.startedAt,
                    endedAt: $0.endedAt,
                    sourceTitle: $0.sourceTitle,
                    correctCount: $0.correctCount,
                    totalCount: $0.totalCount
                )
            },
            calendarEvents: calendarEvents.map {
                MCPCalendarEvent(
                    title: $0.title,
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    kind: $0.kindRawValue,
                    notes: $0.notes
                )
            },
            textDocuments: textDocuments.filter { !$0.isTrashed }.map {
                MCPTextDocument(
                    id: String(describing: $0.persistentModelID),
                    title: $0.title,
                    text: $0.plainText
                )
            },
            slideDecks: slideDecks.filter { !$0.isTrashed }.map { deck in
                MCPSlideDeck(
                    id: String(describing: deck.persistentModelID),
                    title: deck.title,
                    slides: deck.sortedSlides.map {
                        MCPSlideSummary(title: $0.titleText, bullets: $0.bullets, notes: $0.notes)
                    }
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(snapshot)
    }

    @discardableResult
    private func importMCPActions(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let actions = try? decoder.decode([MCPPendingAction].self, from: data), !actions.isEmpty else {
            return false
        }
        applyMCPActions(actions)
        return true
    }

    private func applyMCPActions(_ actions: [MCPPendingAction]) {
        for action in actions {
            switch action.type {
            case "create_flashcards":
                guard let title = action.deckTitle, let cards = action.cards, !cards.isEmpty else { continue }
                let deck = FlashcardDeck(title: title)
                deck.folderName = selectedFolder ?? ""
                for (index, value) in cards.enumerated() {
                    let card = Flashcard(question: value.question, answer: value.answer, order: index)
                    card.deck = deck
                    deck.addCard(card)
                }
                modelContext.insert(deck)
                openFlashcardDeck(deck)
                libraryMode = .studyCards
            case "create_document":
                guard let title = action.title else { continue }
                let document = TextDocument(title: title)
                document.folderName = selectedFolder ?? ""
                let body = DocumentBody.attributedString(fromMarkup: action.body ?? "")
                document.bodyData = DocumentBody.encode(body)
                document.plainText = body.string
                modelContext.insert(document)
                openTextDocument(document)

            case "create_slides":
                guard let title = action.title, let requested = action.slides, !requested.isEmpty else { continue }
                let deck = SlideDeck(title: title)
                deck.folderName = selectedFolder ?? ""
                if let theme = action.theme, let parsed = SlideTheme(rawValue: theme) {
                    deck.theme = parsed
                }
                for (index, source) in requested.enumerated() {
                    let layout = source.layout.flatMap(SlideLayout.init(rawValue:))
                        // A first slide with no bullets reads as a title
                        // slide; everything else defaults to title + content.
                        ?? ((index == 0 && (source.bullets ?? []).isEmpty) ? .titleSlide : .titleAndBody)
                    let slide = Slide(order: index, layout: layout)
                    slide.titleText = source.title ?? ""
                    slide.bodyText = (source.bullets ?? []).joined(separator: "\n")
                    slide.notes = source.notes ?? ""
                    slide.deck = deck
                    deck.addSlide(slide)
                    modelContext.insert(slide)
                }
                modelContext.insert(deck)
                openSlideDeck(deck)

            case "add_calendar_event":
                guard let title = action.title,
                      let startDate = action.startDate,
                      let endDate = action.endDate else { continue }
                let kind = CalendarEventKind(rawValue: action.kind ?? "other") ?? .other
                let event = CalendarEvent(
                    title: title,
                    startDate: startDate,
                    endDate: max(endDate, startDate),
                    kind: kind,
                    notes: action.notes ?? ""
                )
                event.externalSource = "mcp"
                event.externalSourceName = "AI・MCP"
                modelContext.insert(event)
                Task {
                    await UniversityCalendar.requestNotificationPermission()
                    await EventReminderNotifications.schedule(for: event)
                }
                homeSection = .calendar
            default:
                continue
            }
        }
        try? modelContext.save()
    }

    /// Surfaces the server's own error text (e.g. "token has expired") instead
    /// of a generic network error, so an expired/revoked token visibly prompts
    /// the user to reconnect rather than just failing silently.
    private static func mcpCloudServerError(status: Int, body: Data) -> Error {
        struct ServerMessage: Decodable { let error: String? }
        let reason = (try? JSONDecoder().decode(ServerMessage.self, from: body))?.error
        return NSError(
            domain: "MCPCloudSync",
            code: status,
            userInfo: [NSLocalizedDescriptionKey: reason ?? "サーバーエラー（HTTP \(status)）"]
        )
    }

    @MainActor
    private func syncMCPCloud() async {
        let rawEndpoint = mcpCloudEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: rawEndpoint),
              baseURL.scheme?.lowercased() == "https",
              baseURL.host?.isEmpty == false,
              baseURL.user == nil, baseURL.password == nil,
              let snapshotData = makeMCPSnapshotData(),
              mcpCloudToken.count >= 32 else {
            mcpCloudStatus = L("URLまたはトークンを確認してください。")
            return
        }
        MCPCloudCredentials.save(mcpCloudToken)
        isMCPCloudSyncing = true
        defer { isMCPCloudSyncing = false }
        do {
            var upload = URLRequest(url: baseURL.appending(path: "api/snapshot"))
            upload.httpMethod = "PUT"
            upload.httpBody = snapshotData
            upload.setValue("application/json", forHTTPHeaderField: "Content-Type")
            upload.setValue("Bearer \(mcpCloudToken)", forHTTPHeaderField: "Authorization")
            let (uploadData, uploadResponse) = try await URLSession.shared.data(for: upload)
            guard let uploadHTTP = uploadResponse as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard 200..<300 ~= uploadHTTP.statusCode else {
                throw Self.mcpCloudServerError(status: uploadHTTP.statusCode, body: uploadData)
            }

            var download = URLRequest(url: baseURL.appending(path: "api/actions"))
            download.setValue("Bearer \(mcpCloudToken)", forHTTPHeaderField: "Authorization")
            let (actionData, actionResponse) = try await URLSession.shared.data(for: download)
            guard let actionHTTP = actionResponse as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard 200..<300 ~= actionHTTP.statusCode else {
                throw Self.mcpCloudServerError(status: actionHTTP.statusCode, body: actionData)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let actions = (try? decoder.decode([MCPPendingAction].self, from: actionData)) ?? []
            if !actions.isEmpty {
                applyMCPActions(actions)
                var clear = URLRequest(url: baseURL.appending(path: "api/actions"))
                clear.httpMethod = "DELETE"
                clear.setValue("Bearer \(mcpCloudToken)", forHTTPHeaderField: "Authorization")
                _ = try await URLSession.shared.data(for: clear)
            }
            mcpCloudStatus = actions.isEmpty
                ? L("同期しました。新しいAI変更はありません。")
                : L("同期し、\(actions.count)件のAI変更を反映しました。")
        } catch {
            mcpCloudStatus = L("同期できませんでした：\(error.localizedDescription)")
        }
    }

    @discardableResult
    private func importFlashcards(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            return false
        }
        let rows = text.components(separatedBy: .newlines).compactMap { rawLine -> (String, String)? in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let separator: Character = line.contains("\t") ? "\t" : ","
            let parts = splitImportRow(line, separator: separator)
            guard parts.count >= 2 else { return nil }
            let term = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let definition = parts.dropFirst().joined(separator: String(separator))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !definition.isEmpty else { return nil }
            return (term, definition)
        }
        guard !rows.isEmpty else { return false }
        let deck = FlashcardDeck(title: url.deletingPathExtension().lastPathComponent)
        deck.folderName = selectedFolder ?? ""
        for (index, row) in rows.enumerated() {
            let card = Flashcard(question: row.0, answer: row.1, order: index)
            card.deck = deck
            deck.addCard(card)
        }
        modelContext.insert(deck)
        try? modelContext.save()
        libraryMode = .studyCards
        openFlashcardDeck(deck)
        return true
    }

    private func splitImportRow(_ line: String, separator: Character) -> [String] {
        var fields: [String] = []
        var field = ""
        var isQuoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if isQuoted, next < line.endIndex, line[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    isQuoted.toggle()
                }
            } else if character == separator, !isQuoted {
                fields.append(field)
                field = ""
            } else {
                field.append(character)
            }
            index = line.index(after: index)
        }
        fields.append(field)
        return fields
    }

    private func presentPDFUnlockPicker() {
        // Same delayed presentation as the file importer: opening a picker in
        // the transaction that closes the menu is dropped on iPadOS.
        isPickingPDFToUnlock = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            isPickingPDFToUnlock = true
        }
    }

    private func presentFileImporter() {
        // Presenting a document picker in the same transaction that dismisses
        // a toolbar Menu is ignored on iPadOS. Wait for the menu dismissal to
        // complete, then start a fresh presentation transaction.
        isImportingFiles = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            isImportingFiles = true
        }
    }

    private func beginRename(_ notebook: Notebook) {
        renameText = notebook.title
        notebookToRename = notebook
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let path = selectedFolder.map { "\($0)/\(name)" } ?? name
        var names = Set(folderNames)
        names.insert(path)
        folderNamesStorage = names.sorted().joined(separator: "\n")
        var dates = folderCreatedAt
        if dates[path] == nil { dates[path] = Date.now.timeIntervalSince1970 }
        if let data = try? JSONEncoder().encode(dates), let value = String(data: data, encoding: .utf8) {
            folderCreatedAtStorage = value
        }
        selectedFolder = path
        libraryMode = .documents
        newFolderName = ""
    }

    private func goBackOneFolder() {
        guard let selectedFolder else { return }
        self.selectedFolder = parentFolder(of: selectedFolder)
        selectedNotebook = nil
        libraryMode = .documents
    }

    private func beginTagEditing(_ notebook: Notebook) {
        tagsText = notebook.tagsText
        notebookToEditTags = notebook
    }

    private func saveTags() {
        guard let notebookToEditTags else { return }
        notebookToEditTags.tags = tagsText.split(separator: ",").map(String.init)
        notebookToEditTags.updatedAt = .now
        self.notebookToEditTags = nil
    }

    private func renameNotebook() {
        guard let notebookToRename else { return }
        let value = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            notebookToRename.title = value
            notebookToRename.updatedAt = .now
        }
        self.notebookToRename = nil
    }

    private func duplicate(_ source: Notebook) {
        let copy = Notebook(title: "\(source.title) のコピー")
        copy.isFavorite = source.isFavorite
        for original in source.sortedPages {
            let page = NotePage(
                order: original.order,
                backgroundImageData: original.backgroundImageData,
                pageWidth: original.pageWidth,
                pageHeight: original.pageHeight
            )
            page.drawingData = original.drawingData
            page.templateRawValue = original.templateRawValue
            page.isBookmarked = original.isBookmarked
            page.title = original.title
            for originalElement in original.allElements {
                let element = cloneElement(originalElement)
                element.page = page
                page.addElement(element)
            }
            page.notebook = copy
            copy.addPage(page)
        }
        copy.refreshLibraryMetadata()
        modelContext.insert(copy)
        selectedNotebook = copy
    }

    /// Drops a notebook from every open tab and clears any selection or sheet
    /// pointing at it. Called wherever a notebook is trashed or deleted, so a
    /// removed note never lingers as a tab whose content is gone.
    private func closeNotebookTabs(_ notebook: Notebook) {
        openNotebooks.removeAll { $0 === notebook }
        openStudyNotebooks.removeAll { $0 === notebook }
        if selectedNotebook === notebook { selectedNotebook = nil }
        if studyNotebook === notebook { studyNotebook = nil }
    }

    private func closeDeckTabs(_ deck: FlashcardDeck) {
        openFlashcardDecks.removeAll { $0 === deck }
        if selectedFlashcardDeck === deck { selectedFlashcardDeck = nil }
    }

    private func closeDocumentTabs(_ document: TextDocument) {
        openTextDocuments.removeAll { $0 === document }
        if selectedTextDocument === document { selectedTextDocument = openTextDocuments.last }
    }

    private func closeSlideDeckTabs(_ deck: SlideDeck) {
        openSlideDecks.removeAll { $0 === deck }
        if selectedSlideDeck === deck { selectedSlideDeck = openSlideDecks.last }
    }

    /// Soft-deletes a deck/document/slide, matching notes: it goes to the
    /// trash (recoverable) and its tab is closed, rather than being erased.
    private func trashDeck(_ deck: FlashcardDeck) {
        closeDeckTabs(deck)
        deck.isTrashed = true
        deck.trashedAt = .now
    }

    private func trashDocument(_ document: TextDocument) {
        closeDocumentTabs(document)
        document.isTrashed = true
        document.trashedAt = .now
    }

    private func trashSlideDeck(_ deck: SlideDeck) {
        closeSlideDeckTabs(deck)
        deck.isTrashed = true
        deck.trashedAt = .now
    }

    /// True while a note, deck, document or slide is open for study.
    private var isStudySurfaceOpen: Bool {
        selectedNotebook != nil || selectedFlashcardDeck != nil
            || selectedTextDocument != nil || selectedSlideDeck != nil
            || studyNotebook != nil
    }

    /// A value that changes whenever what is open changes, so the tracker can
    /// be told to start or stop.
    private var studySurfaceKey: String {
        [selectedNotebook?.persistentModelID.hashValue,
         selectedFlashcardDeck?.persistentModelID.hashValue,
         selectedTextDocument?.persistentModelID.hashValue,
         selectedSlideDeck?.persistentModelID.hashValue,
         studyNotebook?.persistentModelID.hashValue]
            .map { $0.map(String.init) ?? "-" }
            .joined(separator: ":")
    }

    private func moveToTrash(_ notebook: Notebook) {
        notebook.isTrashed = true
        notebook.trashedAt = .now
        closeNotebookTabs(notebook)
    }

    private func restore(_ notebook: Notebook) {
        notebook.isTrashed = false
        notebook.trashedAt = nil
        libraryMode = .documents
        selectedNotebook = notebook
    }

    private func permanentlyDelete(_ notebook: Notebook) {
        closeNotebookTabs(notebook)
        modelContext.delete(notebook)
    }

    private func emptyTrash() {
        for notebook in allNotebooks where notebook.isTrashed {
            closeNotebookTabs(notebook)
            modelContext.delete(notebook)
        }
        for deck in flashcardDecks where deck.isTrashed { permanentlyDeleteDeck(deck) }
        for document in textDocuments where document.isTrashed { permanentlyDeleteDocument(document) }
        for deck in slideDecks where deck.isTrashed { permanentlyDeleteSlideDeck(deck) }
    }

    /// Whether the trash holds anything at all — notes or any other item.
    private var isTrashEmpty: Bool {
        visibleNotebooks.isEmpty
            && !flashcardDecks.contains(where: \.isTrashed)
            && !textDocuments.contains(where: \.isTrashed)
            && !slideDecks.contains(where: \.isTrashed)
    }

    @MainActor
    private func rebuildLibraryMetadataIfNeeded() async {
        let staleNotebooks = allNotebooks.filter { $0.libraryMetadataVersion < 1 }
        guard notebookLibraryMetadataVersion < 1 || !staleNotebooks.isEmpty else { return }

        try? await Task.sleep(nanoseconds: 350_000_000)
        for notebook in staleNotebooks {
            notebook.refreshLibraryMetadata()
            await Task.yield()
        }
        try? modelContext.save()
        notebookLibraryMetadataVersion = 1
    }

    private func cloneElement(_ source: PageElement) -> PageElement {
        let element = PageElement(
            kind: source.kind,
            text: source.text,
            imageData: source.imageData,
            centerX: source.centerX,
            centerY: source.centerY,
            width: source.width,
            height: source.height,
            rotation: source.rotation,
            colorHex: source.colorHex
        )
        element.isLocked = source.isLocked
        element.layerIndex = source.layerIndex
        return element
    }

    @ViewBuilder
    private func notebookRows(_ notebooks: [Notebook]) -> some View {
        ForEach(notebooks) { notebook in
            NavigationLink(value: notebook) {
                NotebookRow(notebook: notebook)
            }
            .contextMenu {
                notebookActions(notebook)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if !notebook.isTrashed {
                    Button {
                        notebook.isFavorite.toggle()
                    } label: {
                        Label(notebook.isFavorite ? L("解除") : L("お気に入り"), systemImage: notebook.isFavorite ? "star.slash" : "star")
                    }
                    .tint(.yellow)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if notebook.isTrashed {
                    Button("復元") { restore(notebook) }
                        .tint(.green)
                    Button("削除", role: .destructive) { permanentlyDelete(notebook) }
                } else {
                    Button("ゴミ箱", role: .destructive) { moveToTrash(notebook) }
                }
            }
            .draggable("notebook:\(notebookID(notebook))")
        }
    }
}

private struct FileImportPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

private struct NotebookRow: View {
    @Bindable var notebook: Notebook

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notebook.containsPDF ? "doc.richtext" : "note.text")
                .font(.title2)
                .foregroundStyle(notebook.containsPDF ? .red : .blue)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(notebook.title).font(.headline).lineLimit(1)
                    if notebook.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                    }
                }
                Text("\(notebook.pageCountForLibrary)ページ ・ \(notebook.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !notebook.tags.isEmpty {
                    Text(notebook.tags.map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                notebook.isFavorite.toggle()
                notebook.updatedAt = .now
            } label: {
                Image(systemName: notebook.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(notebook.isFavorite ? .yellow : .secondary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

private enum NotebookSortOption: String, CaseIterable, Identifiable {
    case updatedNewest, updatedOldest, createdNewest, createdOldest, nameAscending, nameDescending, pageCount
    var id: String { rawValue }

    var title: String {
        switch self {
        case .updatedNewest: L("更新日が新しい順")
        case .updatedOldest: L("更新日が古い順")
        case .createdNewest: L("作成日が新しい順")
        case .createdOldest: L("作成日が古い順")
        case .nameAscending: L("名前 A–Z")
        case .nameDescending: L("名前 Z–A")
        case .pageCount: L("ページ数が多い順")
        }
    }

    var comparator: (Notebook, Notebook) -> Bool {
        switch self {
        case .updatedNewest: { $0.updatedAt > $1.updatedAt }
        case .updatedOldest: { $0.updatedAt < $1.updatedAt }
        case .createdNewest: { $0.createdAt > $1.createdAt }
        case .createdOldest: { $0.createdAt < $1.createdAt }
        case .nameAscending: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .nameDescending: { $0.title.localizedStandardCompare($1.title) == .orderedDescending }
        case .pageCount: { $0.pageCountForLibrary > $1.pageCountForLibrary }
        }
    }
}

private enum LibraryMode: String, CaseIterable, Identifiable {
    case documents, favorites, pdfs, studyCards, textDocuments, slides, trash
    var id: String { rawValue }

    var title: String {
        switch self {
        case .documents: L("すべて")
        case .favorites: L("お気に入り")
        case .pdfs: "PDF"
        case .studyCards: L("暗記カード")
        case .textDocuments: L("文書")
        case .slides: L("スライド")
        case .trash: L("ゴミ箱")
        }
    }

    var icon: String {
        switch self {
        case .documents: "square.grid.2x2"
        case .favorites: "star"
        case .pdfs: "doc.richtext"
        case .studyCards: "rectangle.on.rectangle.angled"
        case .textDocuments: "doc.text"
        case .slides: "rectangle.on.rectangle"
        case .trash: "trash"
        }
    }

    var emptyTitle: String {
        switch self {
        case .documents: L("ノートがありません")
        case .favorites: L("お気に入りはありません")
        case .pdfs: L("PDFはありません")
        case .studyCards: L("暗記カードはありません")
        case .textDocuments: L("文書はありません")
        case .slides: L("スライドはありません")
        case .trash: L("ゴミ箱は空です")
        }
    }

    var emptyMessage: String {
        switch self {
        case .documents: L("＋からノートを作るかPDFを読み込んでください")
        case .favorites: L("ノートを左へスワイプして登録できます")
        case .pdfs: L("＋からPDFを読み込んでください")
        case .studyCards: L("＋からノートを選んで暗記カードを作成してください")
        case .textDocuments: L("＋から文書を作成してください")
        case .slides: L("＋からスライドを作成してください")
        case .trash: L("削除したノートがここに表示されます")
        }
    }
}
