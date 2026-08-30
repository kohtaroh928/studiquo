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

/// What the tab bar's "+" opens: the same notes and decks the home screen
/// lists, so a second tab can be opened without leaving the editor.
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
                                    Text("\(notebook.pages.count)ページ")
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
                                    Text("\(deck.cards.count)枚")
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
        .presentationDetents([.large, .medium])
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

    static func loadOrCreateToken() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let value = String(data: data, encoding: .utf8), value.count >= 32 {
            return value
        }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        save(value)
        return value
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
        SecItemAdd(item as CFDictionary, nil)
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
    @State private var backupURL: IdentifiableURL?
    @State private var openNotebooks: [Notebook] = []
    @State private var openStudyNotebooks: [Notebook] = []
    @State private var openFlashcardDecks: [FlashcardDeck] = []
    @State private var openWebTabs: [WebTabInfo] = []
    /// One tab per AI conversation, kept here because the tab bar lives here
    /// while the conversations themselves are owned by the open editor.
    @State private var openAIChatTabs: [AIChatTabInfo] = []
    @State private var selectedAIChatTabID: PersistentIdentifier?
    @StateObject private var editorSplitState = EditorSplitState()
    @State private var showsAutomaticBackups = false
    @State private var newNotebookName = ""
    @State private var isShowingNewNotebookAlert = false
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
    @State private var showsTabPicker = false
    @State private var cachedStudyNotifications: [StudyNotification] = []
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("readStudyNotificationIDs") private var readStudyNotificationIDsStorage = ""

    private enum HomeSection: String, CaseIterable, Identifiable {
        case notes = "ノート"
        case calendar = "カレンダー"
        var id: String { rawValue }
        var icon: String { self == .notes ? "note.text" : "calendar" }
        var title: String { self == .notes ? L("ノート") : L("カレンダー") }
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

    var body: some View {
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
        .alert("新規ノート", isPresented: $isShowingNewNotebookAlert) {
            TextField("ノート名", text: $newNotebookName)
            Button("キャンセル", role: .cancel) { newNotebookName = "" }
            Button("作成") { createBlankNotebook() }
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
                urls.forEach(importFile)
                isImportingFiles = false
            } onCancel: {
                isImportingFiles = false
            }
        }
        .fileImporter(isPresented: $isImportingBackup, allowedContentTypes: [.json], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls {
                    if let notebook = NotebookBackupService.restore(from: url) {
                        modelContext.insert(notebook)
                        selectedNotebook = notebook
                    }
                }
            }
        }
        .sheet(item: $backupURL) { wrapped in
            ShareSheet(items: [wrapped.url])
        }
        .sheet(isPresented: $showsAutomaticBackups) {
            AutomaticBackupRestoreView { url in
                if let notebook = NotebookBackupService.restore(from: url) {
                    modelContext.insert(notebook)
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
                            mcpCloudToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                            MCPCloudCredentials.save(mcpCloudToken)
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
        .sheet(isPresented: $showsTabPicker) {
            TabPickerView(
                notebooks: allNotebooks.filter { !$0.isTrashed },
                decks: flashcardDecks,
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
            if !openNotebooks.contains(where: { $0 === notebook }) {
                openNotebooks.append(notebook)
                if openNotebooks.count > 6 { openNotebooks.removeFirst() }
            }
            columnVisibility = .detailOnly
        }
        .onChange(of: selectedFlashcardDeck) { _, deck in
            guard let deck else { return }
            if !openFlashcardDecks.contains(where: { $0 === deck }) {
                openFlashcardDecks.append(deck)
                if openFlashcardDecks.count > 6 { openFlashcardDecks.removeFirst() }
            }
            columnVisibility = .detailOnly
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("StudiquoOpenNotebookTab"))) { notification in
            if let deck = notification.object as? FlashcardDeck {
                if !openFlashcardDecks.contains(where: { $0 === deck }) { openFlashcardDecks.append(deck) }
            } else if let notebook = notification.object as? Notebook,
                      !openNotebooks.contains(where: { $0 === notebook }) {
                openNotebooks.append(notebook)
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
        }
        .onChange(of: scenePhase) { _, phase in
            StudyTimeTracker.shared.handle(scenePhase: phase)
        }
    }

    private var homeDashboard: some View {
        VStack(spacing: 0) {
            if homeSection == .notes {
                fullScreenHome
            } else {
                CalendarHomeView(
                    showsNotifications: $showsNotifications,
                    notificationPanel: { AnyView(notificationPanel) }
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
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var notebookTabBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(openNotebooks) { notebook in
                    HStack(spacing: 5) {
                        Button {
                            selectNotebookTab(notebook)
                        } label: {
                            Label(notebook.title, systemImage: notebook.isLocked ? "lock.fill" : "note.text")
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
                ForEach(openStudyNotebooks) { notebook in
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

                ForEach(openTextDocuments) { document in
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
                ForEach(openSlideDecks) { deck in
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
                            selectedAIChatTabID = tab.id
                            NotificationCenter.default.post(
                                name: .studiquoSelectAIChatTab,
                                object: tab.id
                            )
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

    private func selectFlashcardTab(_ deck: FlashcardDeck) {
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

    private func selectWebTab(_ tab: WebTabInfo) {
        guard selectedNotebook != nil else { return }
        NotificationCenter.default.post(
            name: Notification.Name("StudiquoSwitchPaneTarget"),
            object: PaneSwitchTarget.web(title: tab.title, homeURL: tab.homeURL)
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
        selectedFlashcardDeck = deck
    }

    private func openTextDocument(_ document: TextDocument) {
        clearOpenSelection()
        selectedTextDocument = document
        if !openTextDocuments.contains(where: { $0 === document }) {
            openTextDocuments.append(document)
        }
        columnVisibility = .detailOnly
    }

    private func openSlideDeck(_ deck: SlideDeck) {
        clearOpenSelection()
        selectedSlideDeck = deck
        if !openSlideDecks.contains(where: { $0 === deck }) {
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

    private func handleTabDrop(_ value: String) -> Bool {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        if parts[0] == "deck", let deck = flashcardDecks.first(where: { deckID($0) == parts[1] }) {
            selectedNotebook = nil
            selectedFlashcardDeck = deck
            return true
        }
        guard let notebook = allNotebooks.first(where: { notebookID($0) == parts[1] && !$0.isTrashed }) else { return false }
        if parts[0] == "flashcards" {
            studyNotebook = notebook
        } else {
            selectedFlashcardDeck = nil
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
                        .disabled(visibleNotebooks.isEmpty)
                    } else {
                        createMenu
                    }
                    Button { showsAppSettings = true } label: {
                        Label("設定", systemImage: "gearshape")
                    }
                    .accessibilityLabel("設定")
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
            } else if selectedFolder == nil
                        && !isHomeScreen
                        && visibleNotebooks.isEmpty
                        && displayedFlashcardDecks.isEmpty
                        && displayedTextDocuments.isEmpty
                        && displayedSlideDecks.isEmpty
                        && !(libraryMode == .favorites && hasFavoriteNonNotebookItems) {
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
        flashcardDecks.reduce(0) { $0 + $1.cards.count }
    }

    private var displayedFlashcardDecks: [FlashcardDeck] {
        if libraryMode == .documents {
            return flashcardDecks.filter { $0.folderName == (selectedFolder ?? "") }
        }
        return flashcardDecks
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
                            Text("\(deck.cards.count)枚 ・ 学習\(deck.studySessionCount)回 ・ 正解率\(deck.accuracyText)")
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
                Button("削除", role: .destructive) { modelContext.delete(deck) }
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
                Button("削除", role: .destructive) {
                    openTextDocuments.removeAll { $0 === document }
                    if selectedTextDocument === document { selectedTextDocument = nil }
                    modelContext.delete(document)
                }
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
                            Text("\(deck.slides.count)枚 ・ \(deck.theme.title)")
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
                Button("削除", role: .destructive) {
                    openSlideDecks.removeAll { $0 === deck }
                    if selectedSlideDeck === deck { selectedSlideDeck = nil }
                    modelContext.delete(deck)
                }
            }
            .draggable("slide:\(slideDeckID(deck))")
        }
    }

    private var hasFavoriteNonNotebookItems: Bool {
        !favoriteFolderPaths.isEmpty
            || flashcardDecks.contains(where: \.isFavorite)
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

    private func createBlankNotebook() {
        let title = newNotebookName.trimmingCharacters(in: .whitespacesAndNewlines)
        let notebook = Notebook(title: title.isEmpty ? L("無題のノート") : title)
        let page = NotePage(order: 0)
        page.notebook = notebook
        notebook.pages.append(page)
        notebook.refreshLibraryMetadata()
        notebook.folderName = selectedFolder ?? ""
        modelContext.insert(notebook)
        newNotebookName = ""
        selectedNotebook = notebook
        libraryMode = .documents
    }

    private func importPDF(from url: URL) {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }

        let notebook = Notebook(title: url.deletingPathExtension().lastPathComponent)
        notebook.folderName = selectedFolder ?? ""
        for (index, pageData) in PDFImportService.extractPages(from: url).enumerated() {
            let page = NotePage(order: index, backgroundImageData: pageData.imageData, pageWidth: pageData.width, pageHeight: pageData.height)
            page.recognizedText = pageData.text
            page.textRecognitionDate = .now
            page.notebook = notebook
            notebook.pages.append(page)
        }
        guard !notebook.pages.isEmpty else { return }
        notebook.refreshLibraryMetadata()
        modelContext.insert(notebook)
        selectedNotebook = notebook
        libraryMode = .documents
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
        notebook.pages.append(page)
        notebook.refreshLibraryMetadata()
        modelContext.insert(notebook)
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
                    deck.cards.append(card)
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
                    deck.slides.append(slide)
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

    @MainActor
    private func syncMCPCloud() async {
        let rawEndpoint = mcpCloudEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = URL(string: rawEndpoint),
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
            let (_, uploadResponse) = try await URLSession.shared.data(for: upload)
            guard let uploadHTTP = uploadResponse as? HTTPURLResponse, 200..<300 ~= uploadHTTP.statusCode else {
                throw URLError(.badServerResponse)
            }

            var download = URLRequest(url: baseURL.appending(path: "api/actions"))
            download.setValue("Bearer \(mcpCloudToken)", forHTTPHeaderField: "Authorization")
            let (actionData, actionResponse) = try await URLSession.shared.data(for: download)
            guard let actionHTTP = actionResponse as? HTTPURLResponse, 200..<300 ~= actionHTTP.statusCode else {
                throw URLError(.badServerResponse)
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
            deck.cards.append(card)
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
            for originalElement in original.elements {
                let element = cloneElement(originalElement)
                element.page = page
                page.elements.append(element)
            }
            page.notebook = copy
            copy.pages.append(page)
        }
        copy.refreshLibraryMetadata()
        modelContext.insert(copy)
        selectedNotebook = copy
    }

    private func moveToTrash(_ notebook: Notebook) {
        notebook.isTrashed = true
        notebook.trashedAt = .now
        if selectedNotebook === notebook { selectedNotebook = nil }
    }

    private func restore(_ notebook: Notebook) {
        notebook.isTrashed = false
        notebook.trashedAt = nil
        libraryMode = .documents
        selectedNotebook = notebook
    }

    private func permanentlyDelete(_ notebook: Notebook) {
        if selectedNotebook === notebook { selectedNotebook = nil }
        modelContext.delete(notebook)
    }

    private func emptyTrash() {
        allNotebooks.filter(\.isTrashed).forEach(modelContext.delete)
        selectedNotebook = nil
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
