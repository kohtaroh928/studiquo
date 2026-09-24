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

/// Not `private`: `aiReviewStudyNotifications(from:now:)` below builds these
/// from `AIReviewItem`s and is exercised directly by `AIReviewNotificationFeedTests`.
struct StudyNotification: Identifiable {
    enum Destination { case calendar, aiReview, none }
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

/// The largest attachment `downloadAndPreviewFriendAttachment` will accept
/// from a friend's room. The sender already enforces a 3MB cap before
/// upload (`ProfileAndFriendsView.maximumAttachmentBytes`), but nothing on
/// the receiving side checked the downloaded bytes before writing them to
/// disk and handing them to QuickLook — this is that check, generous enough
/// to never reject a legitimately-sent attachment while still bounding what
/// a compromised sender or server response could make this device store
/// and open.
let maximumFriendAttachmentBytes = 8 * 1024 * 1024

/// Whether a downloaded friend attachment is safe to write to disk and open.
///
/// Beyond the size cap, this checks the bytes' own magic number against
/// what `sourceKind` claims rather than trusting it outright — the
/// attachment's declared kind and file extension both come from the
/// sender's own message payload with no server-side enforcement that they
/// match the actual bytes (see `FriendMessageAttachment`). A generic
/// `"file"` kind has no single expected signature, so it's only bounded by
/// size here.
func isValidFriendAttachment(sourceKind: String, data: Data) -> Bool {
    guard !data.isEmpty, data.count <= maximumFriendAttachmentBytes else { return false }
    switch sourceKind {
    case "photo":
        return data.starts(with: [0xFF, 0xD8, 0xFF]) // JPEG
    case "pdf":
        return data.starts(with: Array("%PDF".utf8))
    default:
        return true
    }
}

/// Prefix shared by an `AIReviewItem`'s bell-feed entry id
/// (`aiReviewNotificationID(for:)`) and its scheduled local notification's
/// identifier (`AIReviewNotifications.identifierPrefix`) — two different
/// systems, kept recognizably named the same way rather than coupled.
let aiReviewNotificationIDPrefix = "ai-review-"

func aiReviewNotificationID(for item: AIReviewItem) -> String {
    aiReviewNotificationIDPrefix + item.id.uuidString
}

/// The bell-feed entries for review items whose `reviewDate` has arrived.
/// A free function (rather than inline in `ContentView.makeStudyNotifications`)
/// so it can be unit tested without instantiating the whole view.
func aiReviewStudyNotifications(from items: [AIReviewItem], now: Date) -> [StudyNotification] {
    items
        .filter { $0.reviewDate <= now }
        .map { item in
            StudyNotification(
                id: aiReviewNotificationID(for: item),
                title: L("復習の時間です"),
                message: L("昨日の質問「\(item.questionText.prefix(40))」を復習できます"),
                detail: item.explanationMarkdown,
                date: item.reviewDate,
                icon: "brain.head.profile",
                tint: .purple,
                destination: .aiReview,
                university: nil
            )
        }
}

func calendarEventTimeRangeText(for event: CalendarEvent, calendar: Calendar = .current) -> String {
    if calendar.isDate(event.startDate, inSameDayAs: event.endDate) {
        return "\(event.startDate.formatted(date: .omitted, time: .shortened))〜\(event.endDate.formatted(date: .omitted, time: .shortened))"
    }
    return "\(event.startDate.formatted(.dateTime.month().day().hour().minute()))〜\(event.endDate.formatted(.dateTime.month().day().hour().minute()))"
}

func calendarEventReminderBody(for event: CalendarEvent, calendar: Calendar = .current) -> String {
    calendarEventTimeRangeText(for: event, calendar: calendar)
}

func studyNotification(forCalendarEvent event: CalendarEvent, now: Date, calendar: Calendar = .current) -> StudyNotification {
    let timing = calendar.isDateInToday(event.startDate)
        ? L("今日")
        : (calendar.isDateInTomorrow(event.startDate)
           ? L("明日")
           : event.startDate.formatted(.dateTime.month().day().weekday(.abbreviated)))
    let eventSummary = L("\(timing)・\(calendarEventTimeRangeText(for: event, calendar: calendar))")
    return StudyNotification(
        id: "event-\(event.createdAt.timeIntervalSince1970)-\(event.title)",
        title: event.title,
        message: eventSummary,
        detail: event.notes.isEmpty ? eventSummary : L("\(eventSummary)\n\(event.notes)"),
        date: event.startDate,
        icon: event.kind.icon,
        tint: event.kind == .test ? .red
            : (event.kind == .classLesson ? .blue : .orange),
        destination: .calendar,
        university: nil
    )
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
    @AppStorage(AIReviewService.isEnabledDefaultsKey) private var aiTalkDayAfterReviewEnabled = true
    @State private var showsAIDataDisclosure = false
    @State private var showsPrivacyPolicy = false
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

                Section {
                    Toggle("翌日復習を作成する", isOn: $aiTalkDayAfterReviewEnabled)
                } header: {
                    Text("AIトーク")
                } footer: {
                    Text("オンにすると、AIトークで質問するたびに復習する価値があるか判定し、翌日に読める解説と確認クイズを自動で作成して通知します。オフにするとこの自動判定・作成は行われません。")
                }

                Section {
                    Button("AI機能とデータ送信について") { showsAIDataDisclosure = true }
                    Button("プライバシーポリシーを見る") { showsPrivacyPolicy = true }
                } header: {
                    Text("プライバシー")
                } footer: {
                    Text("AIトーク・添削・翌日復習を使うと、質問文やノートの内容、答案の写真がGoogleのGeminiに送信されます。詳しくはこちらをご確認ください。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showsAIDataDisclosure) {
                AIDataDisclosureView(buttonTitle: "閉じる") { showsAIDataDisclosure = false }
            }
            .sheet(isPresented: $showsPrivacyPolicy) {
                PrivacyPolicyView()
            }
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

/// Wraps the AI復習 bell-feed wiring (`onChange`/`sheet`) in its own
/// `ViewModifier` rather than chaining them inline on `ContentView.body` —
/// added inline, they pushed the already-huge body expression past what the
/// type checker can solve in reasonable time.
private struct AIReviewIntegration: ViewModifier {
    let count: Int
    @Binding var presentedItem: AIReviewItem?
    let onCountChange: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: count) { _, _ in onCountChange() }
            .sheet(item: $presentedItem) { item in
                AIReviewDetailView(item: item)
            }
    }
}

/// Whether the student has acknowledged that AI features send content
/// off-device. Backs both the first-launch consent screen
/// (`AIDataDisclosureGate`) and the always-available explanation in
/// 設定 → プライバシー — there was previously no disclosure anywhere in the
/// app that note text, answer photos, or chat questions leave the device
/// for Google's Gemini (and, for the separate opt-in bring-your-own-key
/// features, Anthropic).
enum AIDataDisclosure {
    static let acknowledgedDefaultsKey = "hasAcknowledgedAIDataDisclosure"

    /// Swappable so tests can point this at an isolated suite instead of
    /// the real, shared `UserDefaults.standard` — otherwise a manual run of
    /// the app on the same simulator (which really does acknowledge the
    /// disclosure) leaves this `true` for any test that runs afterward.
    static var defaults: UserDefaults = .standard

    /// Defaults to `false` for every install — including an existing
    /// install updating to the version that first added this screen, since
    /// nobody has acknowledged anything yet either way.
    static var hasBeenAcknowledged: Bool {
        defaults.bool(forKey: acknowledgedDefaultsKey)
    }

    static func acknowledge() {
        defaults.set(true, forKey: acknowledgedDefaultsKey)
    }
}

/// Presents `AIDataDisclosureView` full-screen until acknowledged, exactly
/// once. A dedicated `ViewModifier` (rather than a `.fullScreenCover` inline
/// on `ContentView.body`) for the same reason `AIReviewIntegration` above
/// is one: adding modifiers directly to that already-huge body expression
/// pushes Swift's type checker past what it can solve in reasonable time.
private struct AIDataDisclosureGate: ViewModifier {
    @State private var isAcknowledged = AIDataDisclosure.hasBeenAcknowledged

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding(
            get: { !isAcknowledged },
            set: { _ in }
        )) {
            AIDataDisclosureView {
                AIDataDisclosure.acknowledge()
                isAcknowledged = true
            }
        }
    }
}

/// The first-launch (and update-time, for an existing install that never
/// saw this) explanation of what AI features send off-device, and to whom.
private struct AIDataDisclosureView: View {
    var buttonTitle: String = "理解しました"
    let onAcknowledge: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("AI機能について", systemImage: "sparkles")
                            .font(.title2.bold())
                        Text("studiquoのAIトーク・添削・翌日復習は、Googleの生成AI「Gemini」を使っています。これらの機能を使うと、次の内容がGeminiに送信されます。")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        disclosureRow(icon: "text.bubble", title: "AIトークでのやり取り", detail: "送った質問文と、開いているノートの文字起こし内容")
                        disclosureRow(icon: "camera.viewfinder", title: "添削(採点)機能", detail: "問題文や答案として切り抜いた画像・写真")
                        disclosureRow(icon: "calendar.badge.clock", title: "翌日復習機能", detail: "AIトークで送った質問文(内容によっては翌日に復習教材を自動作成します)")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("任意の連携機能", systemImage: "key")
                            .font(.headline)
                        Text("ご自身のAnthropic APIキーを設定した場合のみ、同様の内容がAnthropic(Claude)にも送信されます。キーを設定しない限りこの連携は行われません。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                    Text("この設定は、いつでも設定 → プライバシーから確認できます。AIトークの翌日復習は設定からオフにできます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(22)
            }
            .navigationTitle("はじめに")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button(buttonTitle, action: onAcknowledge)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.bar)
            }
        }
        .interactiveDismissDisabled()
    }

    private func disclosureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// The full privacy policy, shown in-app so it's readable without a network
/// connection. Kept in sync by hand with `legal.js`'s `privacyPolicyHTML()`
/// on the server — that hosted page is the same policy at a public URL, for
/// App Store Connect / Sign in with Apple configuration and anyone sharing a
/// link to it; this sheet is the same wording for someone already inside the
/// app. Editing one without the other lets them drift out of sync.
private struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("studiquoは、利用者の情報をどのように取り扱うかを、このページで説明します。")
                        .foregroundStyle(.secondary)

                    policySection(title: "収集する情報とその利用目的") {
                        bullet("アカウント情報", "サインイン方法に応じて、メールアドレス、Apple IDまたはGoogleアカウントの識別子、氏名の一部を取得します。本アプリの利用を可能にするために使用します。")
                        bullet("プロフィール情報", "設定した表示名。友達機能・共同編集機能で他の利用者に表示するために使用します。")
                        bullet("学習コンテンツ", "ノート、暗記帳、文書、スライドなど、利用者が作成したコンテンツ。本アプリの基本機能を提供するために保存します。")
                        bullet("友達・チャット機能に関する情報", "友達コード、友達関係、チャットメッセージ、送信した添付ファイル。友達同士のコミュニケーション機能を提供するために保存します。")
                        bullet("利用状況", "学習時間の記録、各機能の利用回数。学習記録機能・利用制限の管理のために使用します。")
                        bullet("Googleカレンダー情報", "Googleカレンダー連携を選択した場合、カレンダー名、予定のタイトル、開始・終了日時、説明を読み取り、学習予定と一緒に表示するために端末内へ保存します。Googleカレンダーへの書き込みは行いません。")
                        bullet("AI機能利用時に送信する内容", "AIトーク・添削・翌日復習などの機能を使うと、質問文、ノートの内容、答案の画像などが外部のAIサービスに送信されます。詳しくは次の項目をご覧ください。")
                    }

                    policySection(title: "第三者サービスとの連携") {
                        bullet("Sign in with Apple / Google Sign-In", "アカウント作成・ログインのために使用します。")
                        bullet("Google Calendar API", "許可を得たうえで、選択されているカレンダーの予定を読み取り専用で同期します。取得した情報を広告、行動追跡、第三者への販売には使用しません。")
                        bullet("Google Gemini", "AIトーク・添削・翌日復習機能で、既定の生成AIとして使用します。これらの機能を使うたびに、上記の内容がGoogleに送信されます。")
                        bullet("Anthropic Claude", "利用者が自分自身のAnthropic APIキーを設定した場合に限り、同様の内容がAnthropicにも送信されます。APIキーを設定しない限り、この連携は行われません。")
                        bullet("Cloudflare", "本アプリのサーバーインフラとして使用しており、アカウント情報・学習コンテンツ・チャット内容の保管場所です。")
                        bullet("Apple iCloud", "一部のデータは、CloudKitを通じて利用者ご自身のiCloudアカウント内で端末間同期されます。")
                    }

                    policySection(title: "広告・トラッキングについて") {
                        Text("本アプリは広告配信を行っておらず、第三者による行動トラッキングも行っていません。")
                            .font(.subheadline)
                    }

                    policySection(title: "お子様のご利用について") {
                        Text("本アプリは学生の学習を主な想定用途としていますが、現時点で年齢確認の仕組みはありません。保護者の方は、お子様の利用状況をご確認いただくことをお勧めします。")
                            .font(.subheadline)
                    }

                    policySection(title: "データの削除について") {
                        Text("Google連携はアプリ内からいつでも解除できます。同期したGoogleカレンダーの予定およびその他のアカウントデータの削除をご希望の場合は、お問い合わせ先までご連絡ください。")
                            .font(.subheadline)
                    }

                    policySection(title: "セキュリティについて") {
                        Text("通信は暗号化された経路で行われます。一部のノートは、生体認証や暗号化によって保護する機能を利用できます。ただし、いかなる方法も完全な安全性を保証するものではありません。")
                            .font(.subheadline)
                    }

                    policySection(title: "本ポリシーの変更について") {
                        Text("本ポリシーの内容は、必要に応じて変更されることがあります。重要な変更がある場合は、アプリ内でお知らせします。")
                            .font(.subheadline)
                    }

                    policySection(title: "お問い合わせ先") {
                        Text("本ポリシーや保有する情報の取り扱いに関するご質問・ご請求は、yabukohtaroh@gmail.comまでご連絡ください。")
                            .font(.subheadline)
                    }
                }
                .padding(22)
            }
            .navigationTitle("プライバシーポリシー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func policySection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func bullet(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Notebook.updatedAt, order: .reverse) private var allNotebooks: [Notebook]
    @Query(sort: \FlashcardDeck.updatedAt, order: .reverse) private var flashcardDecks: [FlashcardDeck]
    @Query(sort: \TextDocument.updatedAt, order: .reverse) private var textDocuments: [TextDocument]
    @Query(sort: \SlideDeck.updatedAt, order: .reverse) private var slideDecks: [SlideDeck]
    @Query private var allFolders: [Folder]
    @Query(sort: \CalendarEvent.startDate) private var calendarEvents: [CalendarEvent]
    @Query(sort: \StudyActivity.startedAt, order: .reverse) private var studyActivities: [StudyActivity]
    @Query(sort: \AIReviewItem.reviewDate, order: .reverse) private var aiReviewItems: [AIReviewItem]
    @AppStorage("libraryFolderNames") private var folderNamesStorage = ""
    @AppStorage("libraryFolderCreatedAt") private var folderCreatedAtStorage = "{}"
    @AppStorage("favoriteFolderPaths") private var favoriteFolderPathsStorage = ""
    @AppStorage("notebookLibraryMetadataVersion") private var notebookLibraryMetadataVersion = 0

    @State private var selectedNotebook: Notebook?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var libraryMode: LibraryMode = .documents
    @State private var selectedFolder: String?
    @State private var sortOption: NotebookSortOption = .updatedNewest
    @AppStorage("homeViewMode") private var viewMode: HomeViewMode = .list
    @State private var searchText = ""
    @State private var isImportingFiles = false
    @State private var docxImportFailed = false
    @State private var docxImportReport: String?
    @State private var pptxImportFailed = false
    @State private var pptxImportReport: String?
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
    @State private var emptyPaneDropTarget: String?
    @State private var activeFolderDragPath: String?
    @State private var observedFolderDropHover = false
    /// The `HomeEntry` currently under a drag, across all three view modes —
    /// drives the "+" badge (`entryDropBadge`) shown while dragging one
    /// resource over another, mirroring `folderDropTarget`/`folderDropBadge`.
    @State private var entryDropTarget: PersistentIdentifier?
    @State private var folderToRename: Folder?
    @State private var folderRenameText = ""
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
    @State private var presentedAIReviewItem: AIReviewItem?
    @State private var showsAppSettings = false
    @State private var showsProfile = false
    @AppStorage("profileImage") private var profileImageData = Data()
    @State private var showsTabPicker = false
    @State private var cachedStudyNotifications: [StudyNotification] = []
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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

                return studyNotification(forCalendarEvent: event, now: now, calendar: calendar)
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

        // A review only surfaces once its `reviewDate` — the day after the
        // question was asked — actually arrives, same as the local
        // notification that fires alongside it.
        items += aiReviewStudyNotifications(from: aiReviewItems, now: now)

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
                .accessibilityIdentifier("library-open-notebook-\(selectedNotebook.title)")
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
                        .environmentObject(friendStore)
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
                NavigationStack {
                    LibraryViewSection { AnyView(homeDashboard) }
                }
            } else {
                LibraryViewSection { AnyView(librarySplitView) }
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
        .alert("読み込めませんでした", isPresented: $docxImportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("このファイルは開けませんでした。壊れているか、対応していない形式の可能性があります。")
        }
        .alert("一部の要素は変換できませんでした", isPresented: Binding(
            get: { docxImportReport != nil },
            set: { if !$0 { docxImportReport = nil } }
        )) {
            Button("OK", role: .cancel) { docxImportReport = nil }
        } message: {
            Text((docxImportReport ?? "") + "\nこれらは今のところ非対応のため、文書には含まれていません。")
        }
        .modifier(PptxImportAlerts(importFailed: $pptxImportFailed, importReport: $pptxImportReport))
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
        .alert("パスワードなしで保存しました", isPresented: Binding(
            get: { pdfUnlockedResult != nil },
            set: { if !$0 { pdfUnlockedResult = nil } }
        )) {
            Button("OK", role: .cancel) { pdfUnlockedResult = nil }
        } message: {
            Text("「\(pdfUnlockedResult?.url.lastPathComponent ?? "")」をFilesアプリの「ブラウズ」→「studiquo」→「パスワードなしのPDF」に保存しました。")
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
                        to: PDFPasswordService.savedCopyDestinationURL(for: offer.url)
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
        .modifier(AIReviewIntegration(count: aiReviewItems.count, presentedItem: $presentedAIReviewItem, onCountChange: refreshStudyNotifications))
        .modifier(AIDataDisclosureGate())
        .task {
            await rebuildLibraryMetadataIfNeeded()
        }
        .task {
            await migrateTextDocumentBlocksIfNeeded()
        }
        .task {
            await migrateFoldersIfNeeded()
        }
        .onAppear {
            StudyTimeTracker.shared.configure(context: modelContext)
            StudyTimeTracker.shared.handle(scenePhase: scenePhase)
            StudyTimeTracker.shared.setStudying(isStudySurfaceOpen)
            friendStore.handle(scenePhase: scenePhase)
        }
        .onChange(of: scenePhase) { _, phase in
            StudyTimeTracker.shared.handle(scenePhase: phase)
            friendStore.handle(scenePhase: phase)
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
                LibraryViewSection { AnyView(fullScreenHome) }
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
                    appAttachments: friendMessageAttachmentOptions(),
                    resolveAppAttachment: resolvedAppMessageAttachment
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
                            // A pending friend request used to be invisible
                            // unless this tab happened to already be open —
                            // `friendStore` now polls in the background for
                            // the whole session (see `FriendStore.handle
                            // (scenePhase:)`), so this badge is what actually
                            // surfaces that from anywhere in the app, the
                            // same visual pattern as `notificationBell`'s.
                            .overlay(alignment: .topTrailing) {
                                if section == .friends, friendStore.unseenIncomingRequestCount > 0 {
                                    Text("\(min(friendStore.unseenIncomingRequestCount, 9))")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(minWidth: 15, minHeight: 15)
                                        .background(.red, in: Circle())
                                        .offset(x: -4, y: 2)
                                }
                            }
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
                        Button { selectTextDocumentTab(document) } label: {
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
                    .accessibilityIdentifier("tab-document-\(document.title)")
                    .draggable("document:\(textDocumentID(document))")
                }
                ForEach(openSlideDecks.filter { !$0.isTrashed }) { deck in
                    HStack(spacing: 5) {
                        Button { selectSlideDeckTab(deck) } label: {
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
                    .accessibilityIdentifier("tab-slide-\(deck.title)")
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

    private func selectTextDocumentTab(_ document: TextDocument) {
        if !openTextDocuments.contains(where: { $0.persistentModelID == document.persistentModelID }) {
            openTextDocuments.append(document)
        }
        guard editorSplitState.isSplit, selectedNotebook != nil else {
            openTextDocument(document)
            return
        }
        NotificationCenter.default.post(
            name: Notification.Name("StudiquoSwitchPaneTarget"),
            object: PaneSwitchTarget.document(document)
        )
    }

    private func selectSlideDeckTab(_ deck: SlideDeck) {
        if !openSlideDecks.contains(where: { $0.persistentModelID == deck.persistentModelID }) {
            openSlideDecks.append(deck)
        }
        guard editorSplitState.isSplit, selectedNotebook != nil else {
            openSlideDeck(deck)
            return
        }
        NotificationCenter.default.post(
            name: Notification.Name("StudiquoSwitchPaneTarget"),
            object: PaneSwitchTarget.slideDeck(deck)
        )
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

    private func folderID(_ folder: Folder) -> String {
        String(describing: folder.persistentModelID)
    }

    private func folderDragPayload(for path: String) -> String? {
        folderObject(forLegacyPath: path).map { "folder:\(folderID($0))" }
    }

    private func folderDragProvider(for path: String) -> NSItemProvider {
        activeFolderDragPath = path
        // SwiftUI does not report drag cancellation for String payloads, so
        // expire the hint shortly after the drag starts. Successful drops clear
        // it immediately in `handleFolderDrop`.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if activeFolderDragPath == path { activeFolderDragPath = nil }
        }
        return NSItemProvider(object: (folderDragPayload(for: path) ?? "") as NSString)
    }

    /// Opens `entry` the same way its list row / sidebar button already does
    /// for each concrete type — shared by the icon grid so it doesn't
    /// reimplement per-type navigation.
    private func open(_ entry: HomeEntry) {
        switch entry {
        case .notebook(let notebook):
            selectedNotebook = notebook
            columnVisibility = .detailOnly
        case .flashcardDeck(let deck):
            openFlashcardDeck(deck)
        case .textDocument(let document):
            openTextDocument(document)
        case .slideDeck(let deck):
            openSlideDeck(deck)
        }
    }

    /// Same "type:id" drag payload each list row already writes via
    /// `.draggable(...)`, so `handleFolderDrop` keeps working unchanged for
    /// drags started from the icon grid.
    private func dragPayload(for entry: HomeEntry) -> String {
        switch entry {
        case .notebook(let notebook): "notebook:\(notebookID(notebook))"
        case .flashcardDeck(let deck): "deck:\(deckID(deck))"
        case .textDocument(let document): "document:\(textDocumentID(document))"
        case .slideDeck(let deck): "slide:\(slideDeckID(deck))"
        }
    }

    private func toggleFavorite(_ entry: HomeEntry) {
        switch entry {
        case .notebook(let notebook):
            notebook.isFavorite.toggle()
        case .flashcardDeck(let deck):
            deck.isFavorite.toggle()
            deck.updatedAt = .now
        case .textDocument(let document):
            document.isFavorite.toggle()
            document.updatedAt = .now
        case .slideDeck(let deck):
            deck.isFavorite.toggle()
            deck.updatedAt = .now
        }
    }

    private func trash(_ entry: HomeEntry) {
        switch entry {
        case .notebook(let notebook): moveToTrash(notebook)
        case .flashcardDeck(let deck): trashDeck(deck)
        case .textDocument(let document): trashDocument(document)
        case .slideDeck(let deck): trashSlideDeck(deck)
        }
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
            guard isValidFriendAttachment(sourceKind: sourceKind, data: data) else {
                await MainActor.run {
                    isDownloadingFriendAttachment = false
                    friendStore.errorMessage = "添付ファイルの形式が正しくないため開けませんでした。"
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

    /// Turns a picked in-app material into something the *other* participant
    /// can actually open. `friendMessageAttachmentOptions()` builds each
    /// option's `sourceID` from this device's own SwiftData identifier, which
    /// only resolves against this device's own store — sent as-is, the
    /// recipient's device can never look it up and tapping it silently does
    /// nothing. Rendering it to a PDF and uploading it to the room mirrors
    /// exactly what already works for photo/file attachments (see
    /// `uploadIfPossible` in ProfileAndFriendsView.swift): both sides end up
    /// downloading the same shared bytes instead of one side reading a
    /// pointer only the other side's device could ever have followed.
    private func resolvedAppMessageAttachment(_ attachment: FriendMessageAttachment, friend: FriendRecord) async -> FriendMessageAttachment {
        guard let sourceKind = attachment.resolvedSourceKind,
              let sourceID = attachment.resolvedSourceID,
              let pdfData = ExportService.chatAttachmentPDFData(
                sourceKind: sourceKind,
                sourceID: sourceID,
                notebooks: allNotebooks,
                flashcardDecks: flashcardDecks,
                textDocuments: textDocuments,
                slideDecks: slideDecks
              ) else { return attachment }

        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "FriendChatAttachments", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "\(UUID().uuidString)-\(FriendMessageAttachment.boundedFilename(attachment.title)).pdf")
        guard (try? pdfData.write(to: destination, options: [.atomic])) != nil else { return attachment }

        var remoteID: String?
        var remoteRoomID: String?
        if friend.isDemo != true, let roomID = friend.roomID {
            remoteID = await friendStore.uploadAttachment(data: pdfData, contentType: "application/pdf", roomID: roomID)
            remoteRoomID = remoteID != nil ? roomID : nil
        }

        return FriendMessageAttachment(
            id: attachment.id,
            title: attachment.title,
            kind: attachment.kind,
            icon: attachment.icon,
            sourceKind: "pdf",
            sourceID: remoteID ?? destination.path,
            sourcePath: destination.path,
            remoteRoomID: remoteRoomID
        )
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

    private func resolveFolder(fromDragValue value: String) -> Folder? {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "folder" else { return nil }
        return allFolders.first { folderID($0) == parts[1] }
    }

    private func isFolderDragValue(_ value: String) -> Bool {
        value.split(separator: ":", maxSplits: 1).first.map(String.init) == "folder"
    }

    private func handleFolderDrop(_ values: [String], into folder: String?) -> Bool {
        activeFolderDragPath = nil
        let destination: Folder?
        if let folder {
            guard let found = folderObject(forLegacyPath: folder) else { return false }
            destination = found
        } else {
            destination = nil
        }
        var movedItems: [(item: any HomeItem, folder: Folder?, path: String, updatedAt: Date)] = []
        var movedFolders: [FolderMoveSnapshot] = []
        for value in values {
            if let sourceFolder = resolveFolder(fromDragValue: value) {
                if let snapshot = moveFolder(sourceFolder, into: destination) {
                    movedFolders.append(snapshot)
                }
                continue
            }
            guard let entry = resolveEntry(fromDragValue: value) else { continue }
            let item = entry.underlying
            let previous = (item: item, folder: item.folder, path: item.folderName, updatedAt: item.updatedAt)
            if LibraryFolderMove.move(item, into: destination) {
                movedItems.append(previous)
            }
        }
        guard !movedItems.isEmpty || !movedFolders.isEmpty else { return false }
        do {
            try modelContext.save()
        } catch {
            for previous in movedItems {
                previous.item.folder = previous.folder
                previous.item.folderName = previous.path
                previous.item.updatedAt = previous.updatedAt
            }
            for snapshot in movedFolders.reversed() {
                restoreFolderMove(snapshot)
            }
            return false
        }
        if let folder { expandedSidebarFolders.insert(folder) }
        return true
    }

    private struct FolderMoveSnapshot {
        let folder: Folder
        let parent: Folder?
        let updatedAt: Date
        let folderNamesStorage: String
        let folderCreatedAtStorage: String
        let favoriteFolderPathsStorage: String
        let selectedFolder: String?
        let itemStates: [(item: any HomeItem, folder: Folder?, path: String, updatedAt: Date)]
    }

    private func moveFolder(_ source: Folder, into destination: Folder?) -> FolderMoveSnapshot? {
        guard canMoveFolder(source, into: destination) else { return nil }

        let oldRootPath = source.legacyPath
        let affectedItems = allHomeItems.filter { item in
            item.folderName == oldRootPath || item.folderName.hasPrefix(oldRootPath + "/")
        }
        let snapshot = FolderMoveSnapshot(
            folder: source,
            parent: source.parent,
            updatedAt: source.updatedAt,
            folderNamesStorage: folderNamesStorage,
            folderCreatedAtStorage: folderCreatedAtStorage,
            favoriteFolderPathsStorage: favoriteFolderPathsStorage,
            selectedFolder: selectedFolder,
            itemStates: affectedItems.map { ($0, $0.folder, $0.folderName, $0.updatedAt) }
        )

        source.parent = destination
        source.updatedAt = .now
        let newRootPath = source.legacyPath
        rewriteFolderPathMetadata(from: oldRootPath, to: newRootPath)
        rewriteItemLegacyPaths(from: oldRootPath, to: newRootPath)
        if let selectedFolder, selectedFolder == oldRootPath || selectedFolder.hasPrefix(oldRootPath + "/") {
            self.selectedFolder = replacingFolderPrefix(in: selectedFolder, oldRoot: oldRootPath, newRoot: newRootPath)
        }
        return snapshot
    }

    private var allHomeItems: [any HomeItem] {
        allNotebooks.map { $0 as any HomeItem }
            + flashcardDecks.map { $0 as any HomeItem }
            + textDocuments.map { $0 as any HomeItem }
            + slideDecks.map { $0 as any HomeItem }
    }

    private func canMoveFolder(_ source: Folder, into destination: Folder?) -> Bool {
        guard source.parent !== destination else { return false }
        if let destination {
            guard !source.wouldCreateCycle(ifMovedInto: destination) else { return false }
        }
        guard !folderSiblingNameExists(source.name, under: destination, excluding: source) else { return false }
        return true
    }

    private func canShowDropCue(into destinationPath: String?) -> Bool {
        guard let activeFolderDragPath else { return true }
        guard let source = folderObject(forLegacyPath: activeFolderDragPath) else { return false }
        let destination = destinationPath.flatMap(folderObject(forLegacyPath:))
        if destinationPath != nil && destination == nil { return false }
        return canMoveFolder(source, into: destination)
    }

    private func folderSiblingNameExists(_ name: String, under parent: Folder?, excluding source: Folder) -> Bool {
        allFolders.contains { folder in
            folder !== source && folder.parent === parent && folder.name == name
        }
    }

    private func replacingFolderPrefix(in path: String, oldRoot: String, newRoot: String) -> String {
        guard path != oldRoot else { return newRoot }
        return newRoot + String(path.dropFirst(oldRoot.count))
    }

    private func rewriteFolderPathMetadata(from oldRoot: String, to newRoot: String) {
        let renamedPaths = folderNames.map { path in
            (path == oldRoot || path.hasPrefix(oldRoot + "/"))
                ? replacingFolderPrefix(in: path, oldRoot: oldRoot, newRoot: newRoot)
                : path
        }
        folderNamesStorage = Array(Set(renamedPaths)).sorted().joined(separator: "\n")

        let created = folderCreatedAt
        let renamedCreated = Dictionary(uniqueKeysWithValues: created.map { path, value in
            let newPath = (path == oldRoot || path.hasPrefix(oldRoot + "/"))
                ? replacingFolderPrefix(in: path, oldRoot: oldRoot, newRoot: newRoot)
                : path
            return (newPath, value)
        })
        if let data = try? JSONEncoder().encode(renamedCreated),
           let text = String(data: data, encoding: .utf8) {
            folderCreatedAtStorage = text
        }

        let favorites = favoriteFolderPaths.map { path in
            (path == oldRoot || path.hasPrefix(oldRoot + "/"))
                ? replacingFolderPrefix(in: path, oldRoot: oldRoot, newRoot: newRoot)
                : path
        }
        favoriteFolderPathsStorage = Array(Set(favorites)).sorted().joined(separator: "\n")
    }

    private func rewriteItemLegacyPaths(from oldRoot: String, to newRoot: String) {
        for item in allHomeItems where item.folderName == oldRoot || item.folderName.hasPrefix(oldRoot + "/") {
            item.folderName = replacingFolderPrefix(in: item.folderName, oldRoot: oldRoot, newRoot: newRoot)
            item.updatedAt = .now
        }
    }

    private func restoreFolderMove(_ snapshot: FolderMoveSnapshot) {
        snapshot.folder.parent = snapshot.parent
        snapshot.folder.updatedAt = snapshot.updatedAt
        folderNamesStorage = snapshot.folderNamesStorage
        folderCreatedAtStorage = snapshot.folderCreatedAtStorage
        favoriteFolderPathsStorage = snapshot.favoriteFolderPathsStorage
        selectedFolder = snapshot.selectedFolder
        for state in snapshot.itemStates {
            state.item.folder = state.folder
            state.item.folderName = state.path
            state.item.updatedAt = state.updatedAt
        }
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
                setFolderDropTarget(folder, isTargeted: isTargeted)
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
            LibraryFolderDropSurface(
                identifier: "library-folder-\(folder)",
                onTap: { selectedFolder = folder },
                onDrop: { values in handleFolderDrop(values, into: folder) },
                onTargeted: { isTargeted in
                    setFolderDropTarget(folder, isTargeted: isTargeted)
                }
            )
            .overlay {
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
                .allowsHitTesting(false)
            }
            .frame(height: 54)
            Button { toggleFolderFavorite(folder) } label: {
                Image(systemName: favoriteFolderPaths.contains(folder) ? "star.fill" : "star")
                    .foregroundStyle(favoriteFolderPaths.contains(folder) ? .yellow : .secondary)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onDrag { folderDragProvider(for: folder) }
        .contextMenu {
            if let target = folderObject(forLegacyPath: folder) {
                Button {
                    folderRenameText = target.name
                    folderToRename = target
                } label: {
                    Label("名前を変更", systemImage: "pencil")
                }
            }
        }
    }

    private func folderDropBadge(_ folder: String) -> some View {
        Image(systemName: "plus.circle.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.green)
            .opacity(folderDropTarget == folder ? 1 : 0)
            .scaleEffect(folderDropTarget == folder ? 1 : 0.6)
            .animation(.easeOut(duration: 0.12), value: folderDropTarget)
    }

    private func setFolderDropTarget(_ folder: String, isTargeted: Bool) {
        let canShow = isTargeted && canShowDropCue(into: folder)
        folderDropTarget = canShow ? folder : (folderDropTarget == folder ? nil : folderDropTarget)
        if canShow && ProcessInfo.processInfo.arguments.contains("--library-drop-ui-test") {
            observedFolderDropHover = true
        }
    }

    private func setEmptyPaneDropTarget(_ parentPath: String?, isTargeted: Bool) {
        let key = parentPath ?? ""
        let canShow = isTargeted && canShowDropCue(into: parentPath)
        emptyPaneDropTarget = canShow ? key : (emptyPaneDropTarget == key ? nil : emptyPaneDropTarget)
    }

    /// Same "+" cue as `folderDropBadge`, shown on a resource tile/row while
    /// another resource is being dragged over it — dropping there runs
    /// `handleEntryDrop`, which bundles both into a brand-new folder.
    private func entryDropBadge(_ id: PersistentIdentifier) -> some View {
        Image(systemName: "plus.circle.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.green)
            .opacity(entryDropTarget == id ? 1 : 0)
            .scaleEffect(entryDropTarget == id ? 1 : 0.6)
            .animation(.easeOut(duration: 0.12), value: entryDropTarget)
    }

    private func setEntryDropTarget(_ isTargeted: Bool, _ id: PersistentIdentifier) {
        entryDropTarget = isTargeted ? id : (entryDropTarget == id ? nil : entryDropTarget)
    }

    /// Parses the same "type:id" drag payload `handleFolderDrop` does, but
    /// resolves it back to a `HomeEntry` instead of writing a folder — used
    /// by `handleEntryDrop` to find the resource being dragged onto another
    /// resource.
    private func resolveEntry(fromDragValue value: String) -> HomeEntry? {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "notebook":
            return allNotebooks.first { notebookID($0) == parts[1] && !$0.isTrashed }.map(HomeEntry.notebook)
        case "deck":
            return flashcardDecks.first { deckID($0) == parts[1] }.map(HomeEntry.flashcardDeck)
        case "document":
            return textDocuments.first { textDocumentID($0) == parts[1] && !$0.isTrashed }.map(HomeEntry.textDocument)
        case "slide":
            return slideDecks.first { slideDeckID($0) == parts[1] && !$0.isTrashed }.map(HomeEntry.slideDeck)
        default:
            return nil
        }
    }

    /// Dropping one resource onto another (neither is a folder) bundles both
    /// into a brand-new folder next to wherever the drop target already
    /// lived — the same "drag an app onto another app" gesture iOS's own
    /// home screen uses to create a folder. The new folder opens straight
    /// into the rename alert (`folderToRename`) so it doesn't sit around
    /// nameless.
    private func handleEntryDrop(_ values: [String], onto target: HomeEntry) -> Bool {
        guard let value = values.first, let source = resolveEntry(fromDragValue: value), source.id != target.id,
              !source.isTrashed, !target.isTrashed else {
            return false
        }
        let parentPath = target.underlying.folderName
        let parent = folderObject(forLegacyPath: parentPath)
        guard parentPath.isEmpty || parent != nil else { return false }
        let name = uniqueFolderName(base: "新規フォルダ", parentPath: parentPath)
        let newFolder = Folder(name: name, parent: parent)
        modelContext.insert(newFolder)
        registerFolderPathMetadata(newFolder.legacyPath)
        assign(source.underlying, toLegacyPath: newFolder.legacyPath)
        assign(target.underlying, toLegacyPath: newFolder.legacyPath)
        source.underlying.updatedAt = .now
        target.underlying.updatedAt = .now
        try? modelContext.save()
        folderRenameText = newFolder.name
        folderToRename = newFolder
        return true
    }

    /// "新規フォルダ", "新規フォルダ 2", … — keeps `handleEntryDrop` from ever
    /// creating two same-named siblings, since `folderObject(forLegacyPath:)`
    /// looks folders up by their name-derived path and two identically named
    /// siblings would be ambiguous.
    private func uniqueFolderName(base: String, parentPath: String) -> String {
        let siblingNames = Set(subfolderPaths(of: parentPath.isEmpty ? nil : parentPath).map(folderDisplayName))
        guard siblingNames.contains(base) else { return base }
        var suffix = 2
        while siblingNames.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    /// Registers a freshly-created `Folder`'s path in the same AppStorage
    /// lists `createFolder()` already maintains, so every library view and
    /// the "フォルダへ移動" menu see it immediately.
    private func registerFolderPathMetadata(_ path: String) {
        var names = Set(folderNames)
        names.insert(path)
        folderNamesStorage = names.sorted().joined(separator: "\n")
        var dates = folderCreatedAt
        if dates[path] == nil { dates[path] = Date.now.timeIntervalSince1970 }
        if let data = try? JSONEncoder().encode(dates), let value = String(data: data, encoding: .utf8) {
            folderCreatedAtStorage = value
        }
    }

    private func commitFolderRename() {
        guard let folder = folderToRename else { return }
        let trimmed = folderRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            renameFolder(folder, to: trimmed)
        }
        folderToRename = nil
    }

    private func renameFolder(_ folder: Folder, to newName: String) {
        guard newName != folder.name else { return }
        let oldPath = folder.legacyPath
        folder.name = newName
        folder.updatedAt = .now
        remapLegacyPaths(from: oldPath, to: folder.legacyPath)
    }

    /// Rewrites every *stored* string that encodes a folder path — the
    /// AppStorage-backed folder list/dates/favorites, every item's
    /// `folderName`, and `selectedFolder` if it's inside the affected
    /// subtree — after a `Folder`'s `name` changes. `Folder.legacyPath`
    /// itself needs no such fixup (it's computed live from `parent`/`name`);
    /// all three library views read the stored copies of that path.
    private func remapLegacyPaths(from oldPath: String, to newPath: String) {
        func remap(_ path: String) -> String? {
            if path == oldPath { return newPath }
            if path.hasPrefix(oldPath + "/") { return newPath + path.dropFirst(oldPath.count) }
            return nil
        }

        var names = Set<String>()
        for path in folderNames { names.insert(remap(path) ?? path) }
        folderNamesStorage = names.sorted().joined(separator: "\n")

        var dates = folderCreatedAt
        for (path, value) in folderCreatedAt {
            if let mapped = remap(path) {
                dates.removeValue(forKey: path)
                dates[mapped] = value
            }
        }
        if let data = try? JSONEncoder().encode(dates), let value = String(data: data, encoding: .utf8) {
            folderCreatedAtStorage = value
        }

        var favorites = favoriteFolderPaths
        for path in favoriteFolderPaths {
            if let mapped = remap(path) {
                favorites.remove(path)
                favorites.insert(mapped)
            }
        }
        favoriteFolderPathsStorage = favorites.sorted().joined(separator: "\n")

        for notebook in allNotebooks {
            if let mapped = remap(notebook.folderName) { notebook.folderName = mapped }
        }
        for deck in flashcardDecks {
            if let mapped = remap(deck.folderName) { deck.folderName = mapped }
        }
        for document in textDocuments {
            if let mapped = remap(document.folderName) { document.folderName = mapped }
        }
        for deck in slideDecks {
            if let mapped = remap(deck.folderName) { deck.folderName = mapped }
        }

        if let selectedFolder, let mapped = remap(selectedFolder) {
            self.selectedFolder = mapped
        }
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
        Group {
            if libraryMode == .documents && viewMode == .icon {
                homeIconGrid
            } else if libraryMode == .documents && viewMode == .column {
                columnBrowser
            } else {
                homeList
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
            ToolbarItemGroup(placement: .navigationBarLeading) {
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
                if libraryMode == .documents {
                    ForEach(HomeViewMode.allCases) { mode in
                        Button {
                            viewMode = mode
                        } label: {
                            Image(systemName: mode.systemImage)
                        }
                        .tint(viewMode == mode ? Color.accentColor : Color.secondary)
                        .accessibilityIdentifier("library-view-\(mode.rawValue)")
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
            homeToolbarActions
        }
        .confirmationDialog("ゴミ箱を空にしますか？", isPresented: $showsEmptyTrashConfirmation, titleVisibility: .visible) {
            Button("完全に削除", role: .destructive) { emptyTrash() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は取り消せません。")
        }
        .alert(
            "フォルダ名",
            isPresented: Binding(get: { folderToRename != nil }, set: { if !$0 { folderToRename = nil } })
        ) {
            TextField("フォルダ名", text: $folderRenameText)
            Button("OK") { commitFolderRename() }
            Button("キャンセル", role: .cancel) { folderToRename = nil }
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
        .overlay(alignment: .bottomTrailing) {
            if ProcessInfo.processInfo.arguments.contains("--library-drop-ui-test") {
                Text(observedFolderDropHover ? "shown" : "hidden")
                    .accessibilityIdentifier("library-folder-drop-hover")
                    .font(.system(size: 1))
                    .opacity(0.01)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Each button is its own `ToolbarItem` — not one `HStack` erased into a
    /// single opaque view — so the system toolbar can lay them out and, when
    /// the bar is too narrow, fold the ones that don't fit into its own
    /// "…" overflow menu individually. A single merged view can't be split
    /// that way: iOS treats it as one all-or-nothing element, and when it
    /// doesn't fit, the *whole* HStack silently disappears behind an
    /// unrelated-looking "…" glyph — the buttons look unresponsive because
    /// they aren't where the last-known layout put them, not because a tap
    /// on the visible control failed. Each button stays wrapped in its own
    /// `LibraryViewSection`/`AnyView` boundary (seem `LibraryViewSection`'s
    /// doc comment) so this still avoids building one giant view-expression
    /// tree in one go, the way the single-HStack version did — that part of
    /// the original fix wasn't the problem.
    @ToolbarContentBuilder
    private var homeToolbarActions: some ToolbarContent {
        if isHomeScreen {
            ToolbarItem(placement: .navigationBarTrailing) {
                LibraryViewSection { AnyView(notificationBell) }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            LibraryViewSection { AnyView(primaryLibraryToolbarAction) }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            LibraryViewSection { AnyView(settingsToolbarButton) }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            LibraryViewSection { AnyView(profileToolbarButton) }
        }
    }

    @ViewBuilder
    private var primaryLibraryToolbarAction: some View {
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
    }

    private var settingsToolbarButton: some View {
        Button { showsAppSettings = true } label: {
            Label("設定", systemImage: "gearshape")
        }
        .accessibilityLabel("設定")
    }

    private var profileToolbarButton: some View {
        // `Label { } icon: { }` (icon + title), not a bare `Image`, so that
        // when this button overflows into the toolbar's native "…" menu, the
        // system can lay it out as a normal icon+text row — same as
        // `settingsToolbarButton`'s `Label(_:systemImage:)`. A bare `Image`
        // label has no title for that row template, so it fell back to
        // rendering the icon on its own, clipped and overlapping the
        // neighboring menu item.
        Button { showsProfile = true } label: {
            Label {
                Text("プロフィール")
            } icon: {
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
        }
        .buttonStyle(.plain)
        .accessibilityLabel("プロフィール")
    }

    private var homeList: some View {
        let notebookCounts = Dictionary(
            grouping: allNotebooks.filter { !$0.isTrashed },
            by: \.folderName
        ).mapValues(\.count)
        let deckCounts = Dictionary(grouping: flashcardDecks, by: \.folderName).mapValues(\.count)
        let documentCounts = Dictionary(grouping: textDocuments.filter { !$0.isTrashed }, by: \.folderName).mapValues(\.count)
        let slideCounts = Dictionary(grouping: slideDecks.filter { !$0.isTrashed }, by: \.folderName).mapValues(\.count)

        return Group {
            if libraryMode == .documents {
                // List installs its own row drag/drop interaction. On iPad it
                // consumes drops before a folder row's dropDestination runs.
                // Keep the same rows, but place them in a scroll container so
                // each folder owns its actual drop area.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleFolderPaths, id: \.self) { folder in
                            folderRow(
                                folder,
                                notebookCount: notebookCounts[folder, default: 0],
                                deckCount: deckCounts[folder, default: 0],
                                documentCount: documentCounts[folder, default: 0],
                                slideCount: slideCounts[folder, default: 0]
                            )
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            Divider()
                        }
                        let displayedNotebooks = selectedFolder == nil ? homeNotebooks : visibleNotebooks
                        notebookRows(displayedNotebooks)
                        studyCardRows
                        documentRows
                        slideRows
                    }
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 24))
                    .padding()
                }
            } else {
                List(selection: $selectedNotebook) {
                    if libraryMode == .studyCards && selectedFolder == nil {
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
            }
        }
    }

    /// The Finder-icon-view equivalent of `homeList`, shown only for
    /// `libraryMode == .documents` (the folder-organized "all files" browsing
    /// screen) — the other tabs (favorites, trash, study-cards-only, …) are
    /// single-type filtered lists where an icon grid wouldn't add anything,
    /// so they stay list-only regardless of `viewMode`.
    private var homeIconGrid: some View {
        let notebookCounts = Dictionary(
            grouping: allNotebooks.filter { !$0.isTrashed },
            by: \.folderName
        ).mapValues(\.count)
        let deckCounts = Dictionary(grouping: flashcardDecks, by: \.folderName).mapValues(\.count)
        let documentCounts = Dictionary(grouping: textDocuments.filter { !$0.isTrashed }, by: \.folderName).mapValues(\.count)
        let slideCounts = Dictionary(grouping: slideDecks.filter { !$0.isTrashed }, by: \.folderName).mapValues(\.count)
        let displayedNotebooks = selectedFolder == nil ? homeNotebooks : visibleNotebooks
        let entries: [HomeEntry] =
            displayedNotebooks.map(HomeEntry.notebook)
            + displayedFlashcardDecks.map(HomeEntry.flashcardDeck)
            + displayedTextDocuments.map(HomeEntry.textDocument)
            + displayedSlideDecks.map(HomeEntry.slideDeck)

        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 18)], spacing: 24) {
                ForEach(visibleFolderPaths, id: \.self) { folder in
                    HomeFolderTile(
                        name: folderDisplayName(folder),
                        isFavorite: favoriteFolderPaths.contains(folder),
                        itemCount: notebookCounts[folder, default: 0]
                            + deckCounts[folder, default: 0]
                            + documentCounts[folder, default: 0]
                            + slideCounts[folder, default: 0]
                    ) {
                        selectedFolder = folder
                    }
                    .accessibilityIdentifier("library-folder-\(folder)")
                    .onDrag { folderDragProvider(for: folder) }
                    .overlay(alignment: .bottomTrailing) { folderDropBadge(folder) }
                    .dropDestination(
                        for: String.self,
                        action: { items, _ in handleFolderDrop(items, into: folder) },
                        isTargeted: { isTargeted in
                            setFolderDropTarget(folder, isTargeted: isTargeted)
                        }
                    )
                    .contextMenu {
                        Button {
                            toggleFolderFavorite(folder)
                        } label: {
                            Label(
                                favoriteFolderPaths.contains(folder) ? "お気に入り解除" : "お気に入り",
                                systemImage: favoriteFolderPaths.contains(folder) ? "star.slash" : "star"
                            )
                        }
                        if let target = folderObject(forLegacyPath: folder) {
                            Button {
                                folderRenameText = target.name
                                folderToRename = target
                            } label: {
                                Label("名前を変更", systemImage: "pencil")
                            }
                        }
                    }
                }
                ForEach(entries) { entry in
                    HomeEntryTile(entry: entry) {
                        open(entry)
                    }
                    .accessibilityIdentifier("library-entry-\(entry.title)")
                    .draggable(dragPayload(for: entry))
                    .overlay(alignment: .topTrailing) { entryDropBadge(entry.id) }
                    .dropDestination(
                        for: String.self,
                        action: { items, _ in handleEntryDrop(items, onto: entry) },
                        isTargeted: { isTargeted in setEntryDropTarget(isTargeted, entry.id) }
                    )
                    .contextMenu {
                        Button {
                            toggleFavorite(entry)
                        } label: {
                            Label(entry.isFavorite ? "お気に入り解除" : "お気に入り", systemImage: entry.isFavorite ? "star.slash" : "star")
                        }
                        Button(role: .destructive) {
                            trash(entry)
                        } label: {
                            Label("ゴミ箱", systemImage: "trash")
                        }
                    }
                }
            }
            .padding()
        }
    }

    /// Finder-style Miller-column browser for `libraryMode == .documents`.
    /// One column per folder in `folderChain(endingAt: selectedFolder)`, plus
    /// one more for the deepest folder's own contents. Tapping a subfolder in
    /// any column extends the chain by writing to `selectedFolder` — the same
    /// state the list/icon views already use — so drilling down in one view
    /// mode is immediately reflected if the user switches to another, and
    /// `goBackOneFolder()`/the "ホームへ戻る" button already work unchanged.
    /// Wrapped in `GeometryReader` so the column width can adapt: wide enough
    /// on iPad to show several columns side by side, narrow enough on iPhone
    /// that the browser is really "one column plus a sliver of the next,"
    /// with the rest reached by scrolling horizontally — which is also how
    /// a chain deeper than the screen is wide gets to stay reachable at all.
    private var columnBrowser: some View {
        let chain = folderChain(endingAt: selectedFolder)
        return GeometryReader { geometry in
            let columnWidth: CGFloat = horizontalSizeClass == .compact
                ? max(geometry.size.width - 56, 220)
                : 280
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(0...chain.count, id: \.self) { level in
                            HStack(spacing: 0) {
                                columnPane(
                                    parentPath: level == 0 ? nil : chain[level - 1],
                                    highlightedPath: level < chain.count ? chain[level] : nil
                                )
                                .frame(width: columnWidth)
                                Divider()
                            }
                            .id(level)
                        }
                    }
                }
                .onChange(of: chain.count) { _, newCount in
                    withAnimation { proxy.scrollTo(newCount, anchor: .trailing) }
                }
            }
        }
    }

    /// One column of `columnBrowser`: the folder path's subfolders above its
    /// directly-contained items. `highlightedPath` is the subfolder already
    /// drilled into from this column, if any —
    /// mirroring Finder's "selected row stays tinted in the column it came
    /// from" cue.
    private func columnPane(parentPath: String?, highlightedPath: String?) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
            ForEach(subfolderPaths(of: parentPath), id: \.self) { path in
                Button { selectedFolder = path } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                        Text(folderDisplayName(path)).lineLimit(1)
                        if favoriteFolderPaths.contains(path) {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 45)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .background(path == highlightedPath ? Color.accentColor.opacity(0.15) : Color.clear)
                .accessibilityIdentifier("library-folder-\(path)")
                .onDrag { folderDragProvider(for: path) }
                .overlay(alignment: .trailing) { folderDropBadge(path).padding(.trailing, 28) }
                .dropDestination(for: String.self) { items, _ in
                    handleFolderDrop(items, into: path)
                } isTargeted: { isTargeted in
                    setFolderDropTarget(path, isTargeted: isTargeted)
                }
                .contextMenu {
                    if let folder = folderObject(forLegacyPath: path) {
                        Button {
                            folderRenameText = folder.name
                            folderToRename = folder
                        } label: {
                            Label("名前を変更", systemImage: "pencil")
                        }
                    }
                }
            }
            ForEach(entries(inLegacyPath: parentPath)) { entry in
                Button { open(entry) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: entry.iconName).foregroundStyle(entry.tintColor)
                        Text(entry.title).lineLimit(1)
                        if entry.isFavorite {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 45)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("library-entry-\(entry.title)")
                .draggable(dragPayload(for: entry))
            }
            Rectangle()
                .fill(Color.clear)
                .frame(height: 240)
                .contentShape(Rectangle())
                .accessibilityIdentifier("library-empty-\(parentPath ?? "root")")
                .overlay(alignment: .top) {
                    if emptyPaneDropTarget == (parentPath ?? "") {
                        Label("ここに移動", systemImage: "plus.circle.fill")
                            .foregroundStyle(.green)
                            .padding(.top, 24)
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: String.self) { items, _ in
                    handleFolderDrop(items, into: parentPath)
                } isTargeted: { isTargeted in
                    setEmptyPaneDropTarget(parentPath, isTargeted: isTargeted)
                }
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
        } else if notification.destination == .aiReview {
            guard notification.id.hasPrefix(aiReviewNotificationIDPrefix),
                  let uuid = UUID(uuidString: String(notification.id.dropFirst(aiReviewNotificationIDPrefix.count)))
            else { return }
            presentedAIReviewItem = aiReviewItems.first { $0.id == uuid }
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
                .accessibilityIdentifier("library-entry-\(deck.title)")
                Button { deck.isFavorite.toggle(); deck.updatedAt = .now } label: {
                    Image(systemName: deck.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(deck.isFavorite ? .yellow : .secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library-favorite-\(deck.title)")
                .accessibilityValue(deck.isFavorite ? "on" : "off")
            }
            .swipeActions {
                Button("ゴミ箱", role: .destructive) { trashDeck(deck) }
            }
            .modifier(DocumentLibraryRowStyle(enabled: libraryMode == .documents))
            .draggable("deck:\(deckID(deck))")
            .overlay(alignment: .trailing) { entryDropBadge(HomeEntry.flashcardDeck(deck).id).padding(.trailing, 40) }
            .dropDestination(
                for: String.self,
                action: { items, _ in handleEntryDrop(items, onto: .flashcardDeck(deck)) },
                isTargeted: { isTargeted in setEntryDropTarget(isTargeted, HomeEntry.flashcardDeck(deck).id) }
            )
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
                .accessibilityIdentifier("library-entry-\(document.title)")
                Button { document.isFavorite.toggle(); document.updatedAt = .now } label: {
                    Image(systemName: document.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(document.isFavorite ? .yellow : .secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library-favorite-\(document.title)")
                .accessibilityValue(document.isFavorite ? "on" : "off")
            }
            .swipeActions {
                Button("ゴミ箱", role: .destructive) { trashDocument(document) }
            }
            .modifier(DocumentLibraryRowStyle(enabled: libraryMode == .documents))
            .draggable("document:\(textDocumentID(document))")
            .overlay(alignment: .trailing) { entryDropBadge(HomeEntry.textDocument(document).id).padding(.trailing, 40) }
            .dropDestination(
                for: String.self,
                action: { items, _ in handleEntryDrop(items, onto: .textDocument(document)) },
                isTargeted: { isTargeted in setEntryDropTarget(isTargeted, HomeEntry.textDocument(document).id) }
            )
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
                .accessibilityIdentifier("library-entry-\(deck.title)")
                Button { deck.isFavorite.toggle(); deck.updatedAt = .now } label: {
                    Image(systemName: deck.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(deck.isFavorite ? .yellow : .secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library-favorite-\(deck.title)")
                .accessibilityValue(deck.isFavorite ? "on" : "off")
            }
            .swipeActions {
                Button("ゴミ箱", role: .destructive) { trashSlideDeck(deck) }
            }
            .modifier(DocumentLibraryRowStyle(enabled: libraryMode == .documents))
            .draggable("slide:\(slideDeckID(deck))")
            .overlay(alignment: .trailing) { entryDropBadge(HomeEntry.slideDeck(deck).id).padding(.trailing, 40) }
            .dropDestination(
                for: String.self,
                action: { items, _ in handleEntryDrop(items, onto: .slideDeck(deck)) },
                isTargeted: { isTargeted in setEntryDropTarget(isTargeted, HomeEntry.slideDeck(deck).id) }
            )
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
        folderObject(forLegacyPath: folder)?.isFavorite = favorites.contains(folder)
    }

    /// Looks up the relationship object for a path shared by all library views.
    private func folderObject(forLegacyPath path: String) -> Folder? {
        guard !path.isEmpty else { return nil }
        return allFolders.first { $0.legacyPath == path }
    }

    /// Keep the relationship and the path in sync when an item is moved.
    private func assign<T: HomeItem>(_ item: T, toLegacyPath path: String) {
        item.folderName = path
        item.folder = folderObject(forLegacyPath: path)
    }

    private func assignToCurrentFolder<T: HomeItem>(_ item: T) {
        assign(item, toLegacyPath: selectedFolder ?? "")
    }

    /// Use the same path as list and icon mode. A stale or missing SwiftData
    /// relationship must not make an item appear in a different column.
    private func entries(inLegacyPath path: String?) -> [HomeEntry] {
        let path = path ?? ""
        return allNotebooks.filter { !$0.isTrashed && $0.folderName == path }.map(HomeEntry.notebook)
            + flashcardDecks.filter { !$0.isTrashed && $0.folderName == path }.map(HomeEntry.flashcardDeck)
            + textDocuments.filter { !$0.isTrashed && $0.folderName == path }.map(HomeEntry.textDocument)
            + slideDecks.filter { !$0.isTrashed && $0.folderName == path }.map(HomeEntry.slideDeck)
    }

    private func subfolderPaths(of parentPath: String?) -> [String] {
        sortedFolderNames.filter { parentFolder(of: $0) == parentPath }
    }

    /// One column for each component of the selected path, plus its contents.
    private func folderChain(endingAt path: String?) -> [String] {
        guard let path else { return [] }
        let components = path.split(separator: "/").map(String.init)
        return components.indices.map { components[0...$0].joined(separator: "/") }
    }

    private func createTextDocument() {
        let title = newDocumentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let document = TextDocument(title: title.isEmpty ? L("無題の文書") : title)
        assignToCurrentFolder(document)
        modelContext.insert(document)
        try? modelContext.save()
        newDocumentName = ""
        openTextDocument(document)
    }

    private func createSlideDeck() {
        let title = newSlideDeckName.trimmingCharacters(in: .whitespacesAndNewlines)
        let deck = SlideDeck(title: title.isEmpty ? L("無題のスライド") : title)
        assignToCurrentFolder(deck)
        modelContext.insert(deck)
        try? modelContext.save()
        newSlideDeckName = ""
        openSlideDeck(deck)
    }

    private func createFlashcardDeck() {
        let title = newFlashcardDeckName.trimmingCharacters(in: .whitespacesAndNewlines)
        let deck = FlashcardDeck(title: title.isEmpty ? "新しい暗記帳" : title)
        assignToCurrentFolder(deck)
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
                toggleNotebookProtection(notebook)
            } label: {
                Label(notebook.isLocked ? L("保護を解除") : L("ノートを保護"), systemImage: notebook.isLocked ? "lock.open" : "lock")
            }
            Button {
                backupURL = NotebookBackupService.export(notebook).map(IdentifiableURL.init(url:))
            } label: { Label("バックアップを書き出す", systemImage: "externaldrive") }
            Menu {
                Button { assign(notebook, toLegacyPath: "") } label: { Label("フォルダから外す", systemImage: "tray") }
                ForEach(sortedFolderNames, id: \.self) { folder in
                    Button { assign(notebook, toLegacyPath: folder) } label: {
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
        assignToCurrentFolder(notebook)
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
        assignToCurrentFolder(notebook)
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
                    to: PDFPasswordService.savedCopyDestinationURL(for: url)
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
                    to: PDFPasswordService.savedCopyDestinationURL(for: source)
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
        if fileExtension == "docx" {
            importDocx(from: url)
            return
        }
        if fileExtension == "pptx" {
            importPptx(from: url)
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
        assignToCurrentFolder(notebook)
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

    /// Imports a `.docx` file as a `TextDocument` — per the design's own
    /// decision that an imported docx is always a "文書", never a
    /// handwritten notebook. Parsing happens entirely on-device
    /// (`DocxReader`), so this works offline the same as the existing PDF
    /// import above.
    private func importDocx(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let result = try? DocxReader.read(from: data) else {
            docxImportFailed = true
            return
        }
        let document = TextDocument(title: url.deletingPathExtension().lastPathComponent)
        assignToCurrentFolder(document)
        for block in result.blocks { block.document = document }
        document.blocks = result.blocks
        // Both already reflect exactly what's in `blocks` — no migration
        // needed, unlike a document that starts from the legacy flat
        // `bodyData` representation (see `DocumentBlockMigration`).
        document.isMigratedToBlocks = true
        let wholeText = DocumentBlockText.joinedText(of: result.blocks.filter { $0.kind == .paragraph })
        document.bodyData = DocumentBody.encode(wholeText)
        document.plainText = wholeText.string
        modelContext.insert(document)
        try? modelContext.save()

        if !result.droppedElementKinds.isEmpty {
            // Never let unsupported content vanish without a trace — the
            // design's own non-supported-element policy — shown as a
            // grouped count ("画像 2件, 数式 1件") rather than the raw list.
            let counts = Dictionary(grouping: result.droppedElementKinds, by: { $0 }).mapValues(\.count)
            docxImportReport = counts.sorted(by: { $0.key < $1.key }).map { "\($0.key) \($0.value)件" }.joined(separator: "、")
        }
        openTextDocument(document)
    }

    /// Imports a `.pptx` file as a `SlideDeck` — the same design decision
    /// `importDocx` makes for Word files, just for the slide-deck feature.
    /// `PptxReader` returns slides whose elements already have fully
    /// resolved absolute geometry (design step 8's own scope: it doesn't
    /// try to reconstruct the source file's master/layout hierarchy into
    /// this app's placeholder-inheritance system), so — like `importDocx` —
    /// this skips `SlideBlockMigration` entirely rather than needing it.
    private func importPptx(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let result = try? PptxReader.read(from: data) else {
            pptxImportFailed = true
            return
        }
        let deck = SlideDeck(title: url.deletingPathExtension().lastPathComponent)
        assignToCurrentFolder(deck)
        deck.aspectRawValue = result.aspect.rawValue
        deck.master = SlideMaster.makeDefault()
        deck.isMigratedToElements = true
        for slide in result.slides {
            slide.deck = deck
            deck.addSlide(slide)
        }
        deck.renumberSlides()
        modelContext.insert(deck)
        try? modelContext.save()

        if !result.droppedElementKinds.isEmpty {
            let counts = Dictionary(grouping: result.droppedElementKinds, by: { $0 }).mapValues(\.count)
            pptxImportReport = counts.sorted(by: { $0.key < $1.key }).map { "\($0.key) \($0.value)件" }.joined(separator: "、")
        }
        openSlideDeck(deck)
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
                assignToCurrentFolder(deck)
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
                assignToCurrentFolder(document)
                let body = DocumentBody.attributedString(fromMarkup: action.body ?? "")
                document.bodyData = DocumentBody.encode(body)
                document.plainText = body.string
                modelContext.insert(document)
                openTextDocument(document)

            case "create_slides":
                guard let title = action.title, let requested = action.slides, !requested.isEmpty else { continue }
                let deck = SlideDeck(title: title)
                assignToCurrentFolder(deck)
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
        assignToCurrentFolder(deck)
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
        let typedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parentPath = selectedFolder ?? ""
        let name = typedName.isEmpty ? uniqueNumberedFolderName(parentPath: parentPath) : typedName
        let path = selectedFolder.map { "\($0)/\(name)" } ?? name
        registerFolderPathMetadata(path)
        if folderObject(forLegacyPath: path) == nil {
            let parent = selectedFolder.flatMap(folderObject(forLegacyPath:))
            modelContext.insert(Folder(name: name, parent: parent))
        }
        selectedFolder = path
        libraryMode = .documents
        newFolderName = ""
    }

    private func uniqueNumberedFolderName(parentPath: String) -> String {
        let siblingNames = Set(subfolderPaths(of: parentPath.isEmpty ? nil : parentPath).map(folderDisplayName))
        var suffix = 1
        var candidate = "新規フォルダ（\(suffix)）"
        while siblingNames.contains(candidate) {
            suffix += 1
            candidate = "新規フォルダ（\(suffix)）"
        }
        return candidate
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

    /// Turning protection ON needs no authentication — locking your own
    /// notebook isn't a sensitive action. Turning it OFF used to be just as
    /// unauthenticated, reachable from this same library-list context menu
    /// with no Face ID/passcode check at all — a real gap, since it let
    /// anyone with the device unlocked strip protection from a notebook
    /// without ever proving they were its owner. It now requires the same
    /// check `ProtectedNotebookView` already asks for to open one.
    private func toggleNotebookProtection(_ notebook: Notebook) {
        if notebook.isLocked {
            Task {
                guard await DeviceAuthentication.authenticate(reason: "「\(notebook.title)」の保護を解除します") else { return }
                guard NotebookEncryptionService.unlock(notebook) else { return }
                notebook.isLocked = false
                notebook.updatedAt = .now
            }
        } else {
            NotebookEncryptionService.lock(notebook)
            notebook.isLocked = true
            notebook.updatedAt = .now
            NotebookBackupService.deleteAutomaticBackups(for: notebook)
        }
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

    /// Runs once per launch: converts every `TextDocument` not yet on the
    /// block-based model (see `DocumentBlockMigration`) in the background, so
    /// a document a user never happens to open still ends up migrated rather
    /// than staying on the legacy representation indefinitely. Opening a
    /// document directly (`TextDocumentView.load()`) already migrates it on
    /// the spot; this only catches the rest of the library.
    private func migrateTextDocumentBlocksIfNeeded() async {
        let pending = textDocuments.filter { !$0.isMigratedToBlocks }
        guard !pending.isEmpty else { return }

        try? await Task.sleep(nanoseconds: 350_000_000)
        for document in pending {
            DocumentBlockMigration.migrateIfNeeded(document)
            await Task.yield()
        }
        try? modelContext.save()
    }

    /// Runs once per install: builds real `Folder` records from the legacy
    /// "/"-joined `folderName` path strings and the folder list/metadata
    /// previously kept only in local `UserDefaults`. See
    /// `FolderMigrationService` for the full migration logic.
    private func migrateFoldersIfNeeded() async {
        try? await Task.sleep(nanoseconds: 350_000_000)
        await FolderMigrationService.migrateIfNeeded(
            context: modelContext,
            folderNamesStorage: folderNamesStorage,
            folderCreatedAtStorage: folderCreatedAtStorage,
            favoriteFolderPathsStorage: favoriteFolderPathsStorage,
            notebooks: allNotebooks,
            flashcardDecks: flashcardDecks,
            textDocuments: textDocuments,
            slideDecks: slideDecks
        )
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
            Group {
                // The all-files screen uses ScrollView, not List(selection:), so a
                // NavigationLink(value:) row has no selection binding or
                // navigationDestination to push to and never opens. Open directly
                // there, the same way the icon grid and column browser already do.
                if libraryMode == .documents {
                    Button {
                        open(.notebook(notebook))
                    } label: {
                        NotebookRow(notebook: notebook)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(value: notebook) {
                        NotebookRow(notebook: notebook)
                    }
                }
            }
            .accessibilityIdentifier("library-entry-\(notebook.title)")
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
            .modifier(DocumentLibraryRowStyle(enabled: libraryMode == .documents))
            .onDrag {
                return NSItemProvider(object: "notebook:\(notebookID(notebook))" as NSString)
            }
            .overlay(alignment: .trailing) { entryDropBadge(HomeEntry.notebook(notebook).id).padding(.trailing, 12) }
            .dropDestination(
                for: String.self,
                action: { items, _ in handleEntryDrop(items, onto: .notebook(notebook)) },
                isTargeted: { isTargeted in setEntryDropTarget(isTargeted, HomeEntry.notebook(notebook).id) }
            )
        }
    }
}

/// The all-files screen uses ScrollView so folder rows can receive drops.
/// List used to supply these insets and separators automatically.
private struct DocumentLibraryRowStyle: ViewModifier {
    let enabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content
                .buttonStyle(.plain)
                .frame(minHeight: 54)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    Divider().allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}

/// SwiftUI's folder row sits inside nested navigation and scroll containers.
/// A UIKit drop interaction owns the complete visible row, so its hover and
/// drop callbacks are delivered even when SwiftUI's row modifiers are not.
private struct LibraryFolderDropSurface: UIViewRepresentable {
    let identifier: String
    let onTap: () -> Void
    let onDrop: ([String]) -> Bool
    let onTargeted: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = true
        view.accessibilityTraits = .button
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = String(identifier.dropFirst("library-folder-".count))
        view.addInteraction(UIDropInteraction(delegate: context.coordinator))
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)))
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = String(identifier.dropFirst("library-folder-".count))
    }

    final class Coordinator: NSObject, UIDropInteractionDelegate {
        var parent: LibraryFolderDropSurface

        init(_ parent: LibraryFolderDropSurface) { self.parent = parent }

        @objc func tapped() { parent.onTap() }

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            session.canLoadObjects(ofClass: NSString.self)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
            parent.onTargeted(true)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
            parent.onTargeted(false)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
            parent.onTargeted(false)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            return UIDropProposal(operation: .move)
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            parent.onTargeted(false)
            for item in session.items {
                _ = item.itemProvider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                    guard let value = object as? String else { return }
                    DispatchQueue.main.async { _ = self?.parent.onDrop([value]) }
                }
            }
        }
    }
}

/// Bundles both pptx-import alerts into one `.modifier(...)` call rather
/// than two separate `.alert(...)`s on `ContentView`'s already very long
/// top-level modifier chain — that chain hit Swift's type-checker
/// complexity limit ("unable to type-check this expression in reasonable
/// time") the moment these two were added directly, the same way the
/// existing docx-import alerts already sit right below the chain's limit.
private struct PptxImportAlerts: ViewModifier {
    @Binding var importFailed: Bool
    @Binding var importReport: String?

    func body(content: Content) -> some View {
        content
            .alert("読み込めませんでした", isPresented: $importFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("このファイルは開けませんでした。壊れているか、対応していない形式の可能性があります。")
            }
            .alert("一部の要素は変換できませんでした", isPresented: Binding(
                get: { importReport != nil },
                set: { if !$0 { importReport = nil } }
            )) {
                Button("OK", role: .cancel) { importReport = nil }
            } message: {
                Text((importReport ?? "") + "\nこれらは今のところ非対応のため、スライドには含まれていません。")
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

/// One folder tile in `ContentView.homeIconGrid`. Visually mirrors
/// `folderRow`'s list row (same folder glyph, same favorite star, same drop
/// badge) but laid out as an icon-and-label tile instead of a horizontal row.
private struct HomeFolderTile: View {
    let name: String
    let isFavorite: Bool
    let itemCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(name)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                Text("\(itemCount)項目")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 104)
    }
}

/// One notebook/deck/document/slide tile in `ContentView.homeIconGrid`. Takes
/// a `HomeEntry` rather than one of the four concrete model types so the grid
/// can render all of them with a single `ForEach`.
private struct HomeEntryTile: View {
    let entry: HomeEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: entry.iconName)
                        .font(.system(size: 40))
                        .foregroundStyle(entry.tintColor)
                    if entry.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(entry.title)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 104)
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
            .accessibilityIdentifier("library-favorite-\(notebook.title)")
            .accessibilityValue(notebook.isFavorite ? "on" : "off")
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

/// How `ContentView.fullScreenHome` lays out the "all files" browsing screen
/// (`LibraryMode.documents`) — a Finder-style icon/list/column switch.
/// Persisted app-wide via `@AppStorage`, matching the earlier design decision
/// to remember one view mode for the whole app rather than per folder.
private enum HomeViewMode: String, CaseIterable, Identifiable {
    case list, icon, column
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .icon: "square.grid.2x2"
        case .column: "rectangle.split.3x1"
        }
    }
}

/// Keep construction of each large library section in a separate SwiftUI
/// body evaluation. Eagerly composing all sections and toolbar menus inside
/// ContentView exhausted the main-thread stack on iPad (EXC_BAD_ACCESS in
/// fullScreenHome's toolbar type metadata). The closure keeps the parent
/// view small, and AnyView bounds the type at this coarse section boundary.
private struct LibraryViewSection: View {
    let content: () -> AnyView

    var body: some View { content() }
}
