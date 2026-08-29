import SwiftUI
import SwiftData
import Security
import UIKit
import UserNotifications

/// Any university that publishes an iCalendar feed from its LMS — Moodle,
/// Canvas, Sakai, manaba — can be connected. The feed is fetched over HTTPS
/// and parsed here; the institution is identified from the URL's domain
/// purely so imported items can be labelled, and an unrecognised domain
/// still syncs.
enum UniversityCalendar {
    static let externalSource = "university"

    private static let service = "com.yabuko.studiquo.university-calendar"
    /// Where the Waseda-only build stored its link, read once so anyone who
    /// already connected keeps their calendar after updating.
    private static let legacyService = "com.yabuko.studiquo.waseda-moodle"
    private static let account = "calendar-url"
    private static let storedNameKey = "universityCalendarName"

    /// Domain suffix → display name. Matching the university's own domain
    /// rather than the LMS host means a school's Moodle keeps working even
    /// when it lives on a subdomain this table has never seen.
    static let directory: [(domain: String, name: String)] = [
        ("waseda.jp", "早稲田大学"),
        ("keio.jp", "慶應義塾大学"),
        ("u-tokyo.ac.jp", "東京大学"),
        ("kyoto-u.ac.jp", "京都大学"),
        ("osaka-u.ac.jp", "大阪大学"),
        ("tohoku.ac.jp", "東北大学"),
        ("nagoya-u.ac.jp", "名古屋大学"),
        ("kyushu-u.ac.jp", "九州大学"),
        ("hokudai.ac.jp", "北海道大学"),
        ("hit-u.ac.jp", "一橋大学"),
        ("isct.ac.jp", "東京科学大学"),
        ("titech.ac.jp", "東京科学大学"),
        ("tsukuba.ac.jp", "筑波大学"),
        ("kobe-u.ac.jp", "神戸大学"),
        ("hiroshima-u.ac.jp", "広島大学"),
        ("okayama-u.ac.jp", "岡山大学"),
        ("chiba-u.ac.jp", "千葉大学"),
        ("saitama-u.ac.jp", "埼玉大学"),
        ("ibaraki.ac.jp", "茨城大学"),
        ("gunma-u.ac.jp", "群馬大学"),
        ("utsunomiya-u.ac.jp", "宇都宮大学"),
        ("shinshu-u.ac.jp", "信州大学"),
        ("niigata-u.ac.jp", "新潟大学"),
        ("kanazawa-u.ac.jp", "金沢大学"),
        ("u-toyama.ac.jp", "富山大学"),
        ("u-fukui.ac.jp", "福井大学"),
        ("shizuoka.ac.jp", "静岡大学"),
        ("gifu-u.ac.jp", "岐阜大学"),
        ("mie-u.ac.jp", "三重大学"),
        ("yamanashi.ac.jp", "山梨大学"),
        ("wakayama-u.ac.jp", "和歌山大学"),
        ("tottori-u.ac.jp", "鳥取大学"),
        ("shimane-u.ac.jp", "島根大学"),
        ("yamaguchi-u.ac.jp", "山口大学"),
        ("tokushima-u.ac.jp", "徳島大学"),
        ("kagawa-u.ac.jp", "香川大学"),
        ("ehime-u.ac.jp", "愛媛大学"),
        ("kochi-u.ac.jp", "高知大学"),
        ("nagasaki-u.ac.jp", "長崎大学"),
        ("kumamoto-u.ac.jp", "熊本大学"),
        ("oita-u.ac.jp", "大分大学"),
        ("saga-u.ac.jp", "佐賀大学"),
        ("kagoshima-u.ac.jp", "鹿児島大学"),
        ("ryukyu.ac.jp", "琉球大学"),
        ("hirosaki-u.ac.jp", "弘前大学"),
        ("iwate-u.ac.jp", "岩手大学"),
        ("akita-u.ac.jp", "秋田大学"),
        ("yamagata-u.ac.jp", "山形大学"),
        ("tuat.ac.jp", "東京農工大学"),
        ("uec.ac.jp", "電気通信大学"),
        ("tufs.ac.jp", "東京外国語大学"),
        ("ocha.ac.jp", "お茶の水女子大学"),
        ("geidai.ac.jp", "東京藝術大学"),
        ("tmu.ac.jp", "東京都立大学"),
        ("naist.jp", "奈良先端科学技術大学院大学"),
        ("jaist.ac.jp", "北陸先端科学技術大学院大学"),
        ("meiji.ac.jp", "明治大学"),
        ("rikkyo.ac.jp", "立教大学"),
        ("hosei.ac.jp", "法政大学"),
        ("chuo-u.ac.jp", "中央大学"),
        ("sophia.ac.jp", "上智大学"),
        ("aoyama.ac.jp", "青山学院大学"),
        ("gakushuin.ac.jp", "学習院大学"),
        ("tus.ac.jp", "東京理科大学"),
        ("nihon-u.ac.jp", "日本大学"),
        ("toyo.ac.jp", "東洋大学"),
        ("komazawa-u.ac.jp", "駒澤大学"),
        ("senshu-u.ac.jp", "専修大学"),
        ("tokai.ac.jp", "東海大学"),
        ("teikyo-u.ac.jp", "帝京大学"),
        ("kokugakuin.ac.jp", "國學院大學"),
        ("seikei.ac.jp", "成蹊大学"),
        ("seijo.ac.jp", "成城大学"),
        ("musashi.ac.jp", "武蔵大学"),
        ("soka.ac.jp", "創価大学"),
        ("shibaura-it.ac.jp", "芝浦工業大学"),
        ("icu.ac.jp", "国際基督教大学"),
        ("tsuda.ac.jp", "津田塾大学"),
        ("jwu.ac.jp", "日本女子大学"),
        ("twcu.ac.jp", "東京女子大学"),
        ("ritsumei.ac.jp", "立命館大学"),
        ("apu.ac.jp", "立命館アジア太平洋大学"),
        ("doshisha.ac.jp", "同志社大学"),
        ("kansai-u.ac.jp", "関西大学"),
        ("kwansei.ac.jp", "関西学院大学"),
        ("kindai.ac.jp", "近畿大学"),
        ("ryukoku.ac.jp", "龍谷大学"),
        ("oit.ac.jp", "大阪工業大学"),
        ("nanzan-u.ac.jp", "南山大学"),
        ("meijo-u.ac.jp", "名城大学"),
        ("nodai.ac.jp", "東京農業大学"),
        ("kitasato-u.ac.jp", "北里大学"),
        ("juntendo.ac.jp", "順天堂大学"),
        ("fukuoka-u.ac.jp", "福岡大学"),
        ("seinan-gu.ac.jp", "西南学院大学"),
    ]

    /// Best-effort label for the feed's owner. `nil` for a school that isn't
    /// in the table — syncing is unaffected, the items are just labelled
    /// with the host instead.
    static func universityName(forURL raw: String) -> String? {
        guard let host = URL(string: normalizedURLString(raw))?.host?.lowercased() else { return nil }
        return directory.first { host == $0.domain || host.hasSuffix("." + $0.domain) }?.name
    }

    /// What imported items are labelled with: the recognised university name,
    /// or the feed's host when the school isn't in the table.
    static func displayName(forURL raw: String) -> String {
        if let known = universityName(forURL: raw) { return known }
        return URL(string: normalizedURLString(raw))?.host ?? "大学"
    }

    static var storedName: String? {
        get { UserDefaults.standard.string(forKey: storedNameKey) }
        set { UserDefaults.standard.setValue(newValue, forKey: storedNameKey) }
    }

    static func loadURL() -> String {
        if let value = keychainValue(service: service) { return value }
        // Carry over the link saved by the Waseda-only build.
        if let legacy = keychainValue(service: legacyService) {
            saveURL(legacy)
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
            return legacy
        }
        return ""
    }

    private static func keychainValue(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func saveURL(_ value: String) {
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

    static func removeURL() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    struct Event {
        let id: String
        let title: String
        let startDate: Date
        let endDate: Date
        let notes: String
        let isAllDay: Bool
    }

    /// LMS subscription links are handed out as `webcal://`, which
    /// `URLSession` refuses to load — the scheme only tells the OS to open a
    /// calendar app. The address behind it is an ordinary HTTPS one.
    static func normalizedURLString(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["webcal://", "webcals://"] where value.lowercased().hasPrefix(scheme) {
            value = "https://" + value.dropFirst(scheme.count)
        }
        return value
    }

    static func fetch(from rawURL: String) async throws -> [Event] {
        guard let url = URL(string: normalizedURLString(rawURL)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.contains(".") == true else {
            throw SyncError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SyncError.downloadFailed
        }
        // Feeds are UTF-8 in practice; fall back to Latin-1 so a mis-declared
        // one still parses instead of silently importing nothing.
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1),
              text.contains("BEGIN:VCALENDAR") else {
            throw SyncError.notACalendar
        }
        return parse(text)
    }

    /// One `NAME;PARAM=value:content` line. The parameters matter: they carry
    /// `TZID`, which decides what wall-clock time a deadline actually lands
    /// on, and `VALUE=DATE`, which marks an all-day entry.
    private struct Property {
        let name: String
        let parameters: [String: String]
        let value: String
    }

    private static func parse(_ text: String) -> [Event] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.count - 1] += String(line.dropFirst())
            } else {
                lines.append(line)
            }
        }

        var result: [Event] = []
        var fields: [String: Property] = [:]
        var inEvent = false
        var alarmDepth = 0

        for line in lines {
            let marker = line.trimmingCharacters(in: .whitespaces).uppercased()
            if marker == "BEGIN:VEVENT" { inEvent = true; alarmDepth = 0; fields = [:]; continue }
            if marker == "END:VEVENT" {
                if let event = event(from: fields) { result.append(event) }
                inEvent = false
                continue
            }
            guard inEvent else { continue }
            // A VALARM carries its own TRIGGER/DESCRIPTION; folding those in
            // would overwrite the event's own description.
            if marker.hasPrefix("BEGIN:") && marker != "BEGIN:VEVENT" { alarmDepth += 1; continue }
            if marker.hasPrefix("END:") { alarmDepth = max(0, alarmDepth - 1); continue }
            guard alarmDepth == 0, let property = property(from: line) else { continue }
            fields[property.name] = property
        }
        return result
    }

    private static func property(from line: String) -> Property? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let head = String(line[..<colon])
        let value = String(line[line.index(after: colon)...])
        let segments = head.split(separator: ";").map(String.init)
        guard let name = segments.first?.trimmingCharacters(in: .whitespaces).uppercased(),
              !name.isEmpty else { return nil }
        var parameters: [String: String] = [:]
        for segment in segments.dropFirst() {
            let pair = segment.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            parameters[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return Property(name: name, parameters: parameters, value: value)
    }

    private static func event(from fields: [String: Property]) -> Event? {
        guard let title = fields["SUMMARY"]?.value, !title.isEmpty,
              let start = date(from: fields["DTSTART"]) else { return nil }

        let end: Date
        if let explicit = date(from: fields["DTEND"]) {
            // An all-day DTEND is exclusive: it names the morning *after*.
            end = start.isAllDay ? explicit.date.addingTimeInterval(-1) : explicit.date
        } else if let seconds = duration(from: fields["DURATION"]?.value) {
            end = start.date.addingTimeInterval(seconds)
        } else if start.isAllDay {
            end = start.date.addingTimeInterval(86_399)
        } else {
            end = start.date
        }

        let identifier = fields["UID"]?.value
            ?? "\(title)-\(start.date.timeIntervalSince1970)"
        return Event(
            id: identifier,
            title: unescape(title),
            startDate: start.date,
            endDate: max(end, start.date),
            notes: unescape(fields["DESCRIPTION"]?.value ?? ""),
            isAllDay: start.isAllDay
        )
    }

    /// The zone comes from the value itself: a trailing `Z` means UTC, and
    /// otherwise the property's own `TZID` decides. Reading `TZID` matters now
    /// that any university can connect — the previous code discarded every
    /// parameter and assumed Asia/Tokyo, which is wrong for a school (or a
    /// feed) on another clock. Each form is matched by exact length because
    /// `date(from:)` ignores trailing characters, so a loose pattern can
    /// quietly accept a value it only partly understood.
    private static func date(from property: Property?) -> (date: Date, isAllDay: Bool)? {
        guard let property else { return nil }
        let raw = property.value.trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if raw.hasSuffix("Z"), raw.count == 16 {
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            if let date = formatter.date(from: String(raw.dropLast())) { return (date, false) }
        }

        let zone = property.parameters["TZID"].flatMap(TimeZone.init(identifier:))
            ?? TimeZone(identifier: "Asia/Tokyo")
            ?? .current
        formatter.timeZone = zone

        if raw.count == 15 {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            if let date = formatter.date(from: raw) { return (date, false) }
        }
        if raw.count == 8 {
            formatter.dateFormat = "yyyyMMdd"
            if let date = formatter.date(from: raw) { return (date, true) }
        }
        return nil
    }

    private static func duration(from value: String?) -> TimeInterval? {
        guard var text = value?.trimmingCharacters(in: .whitespaces).uppercased() else { return nil }
        let isNegative = text.hasPrefix("-")
        if isNegative || text.hasPrefix("+") { text.removeFirst() }
        guard text.hasPrefix("P") else { return nil }
        text.removeFirst()

        var total: TimeInterval = 0
        var digits = ""
        var inTimeSection = false
        for character in text {
            if character == "T" { inTimeSection = true; continue }
            if character.isNumber { digits.append(character); continue }
            let amount = TimeInterval(digits) ?? 0
            digits = ""
            switch character {
            case "W": total += amount * 604_800
            case "D": total += amount * 86_400
            case "H": total += amount * 3_600
            case "M": total += inTimeSection ? amount * 60 : 0
            case "S": total += amount
            default: break
            }
        }
        return isNegative ? -total : total
    }

    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    enum SyncError: LocalizedError {
        case invalidURL, downloadFailed, notACalendar
        var errorDescription: String? {
            switch self {
            case .invalidURL:
                L("カレンダーURLの形式が正しくありません。大学のLMSで発行したリンクを貼り付けてください。")
            case .downloadFailed:
                L("カレンダーを取得できませんでした。通信状況を確認し、URLを再発行してお試しください。")
            case .notACalendar:
                L("このURLからカレンダーを読み取れませんでした。エクスポート用のリンクか確認してください。")
            }
        }
    }

    private static let notificationIdentifierPrefix = "university-deadline-"

    static func requestNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func scheduleDeadlineNotifications(for items: [Event], university: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let pending = await center.pendingNotificationRequests()
        let obsolete = pending.map(\.identifier).filter { $0.hasPrefix(notificationIdentifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: obsolete)

        let calendar = Calendar.current
        let now = Date.now
        for item in items where item.endDate > now {
            var fireDate = calendar.date(
                bySettingHour: 8, minute: 0, second: 0,
                of: calendar.startOfDay(for: item.startDate)
            ) ?? item.startDate
            if fireDate <= now {
                fireDate = now.addingTimeInterval(60)
            }

            let content = UNMutableNotificationContent()
            content.title = L("\(university)・今日締切の予定があります")
            content.body = item.isAllDay
                ? item.title
                : L("\(item.title)・\(item.endDate.formatted(date: .omitted, time: .shortened))まで")
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: notificationIdentifierPrefix + item.id,
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }

    static func cancelAllDeadlineNotifications() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let obsolete = requests.map(\.identifier).filter { $0.hasPrefix(notificationIdentifierPrefix) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: obsolete)
        }
    }
}

struct CalendarHomeView: View {
    var onShowNotifications: () -> Void = {}
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CalendarEvent.startDate) private var events: [CalendarEvent]
    @Query(sort: \StudyActivity.startedAt, order: .reverse) private var studyActivities: [StudyActivity]
    @State private var selectedDate = Date.now
    @State private var displayedMonth = Date.now
    @State private var showsNewEvent = false
    @State private var editingEvent: CalendarEvent?
    @State private var showsUniversityConnection = false
    @State private var universityCalendarURL = UniversityCalendar.loadURL()
    @State private var universityStatus = ""
    @State private var isUniversitySyncing = false

    /// Includes anything running *through* the day, not just starting on it,
    /// so a multi-day entry stays visible for its whole span.
    private var selectedDayEvents: [CalendarEvent] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: selectedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return events.filter { $0.startDate < dayEnd && $0.endDate >= dayStart }
    }

    /// Which event kinds land on each day, so the calendar grid can mark a
    /// day without the cost of re-scanning every event per cell. A multi-day
    /// entry marks every day it spans, not just the one it starts on.
    private var eventKindsByDay: [Date: Set<CalendarEventKind>] {
        let calendar = Calendar.current
        var result: [Date: Set<CalendarEventKind>] = [:]
        for event in events {
            var cursor = calendar.startOfDay(for: event.startDate)
            let lastDay = calendar.startOfDay(for: event.endDate)
            var daysWalked = 0
            while cursor <= lastDay, daysWalked < 366 {
                result[cursor, default: []].insert(event.kind)
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
                daysWalked += 1
            }
        }
        return result
    }

    private var todayStudySeconds: TimeInterval {
        studyActivities.filter { Calendar.current.isDateInToday($0.startedAt) }.reduce(0) { $0 + $1.duration }
    }

    private var currentStudyStreak: Int {
        let calendar = Calendar.current
        let studiedDays = Set(studyActivities.map { calendar.startOfDay(for: $0.startedAt) })
        var cursor = calendar.startOfDay(for: .now)
        if !studiedDays.contains(cursor), let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = yesterday
        }
        var streak = 0
        while studiedDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width >= 760 {
                    HStack(spacing: 0) {
                        calendarPanel
                            .frame(maxWidth: .infinity)
                        Divider()
                        eventList
                            .frame(width: min(420, geometry.size.width * 0.38))
                    }
                } else {
                    VStack(spacing: 0) {
                        calendarPanel
                        Divider()
                        eventList
                    }
                }
            }
        }
        .navigationTitle("カレンダー")
        // Keeps the grid on the right month when selectedDate is moved from
        // outside this view — e.g. tapping a notification for a future date.
        .onChange(of: selectedDate) { _, newValue in
            if !Calendar.current.isDate(newValue, equalTo: displayedMonth, toGranularity: .month) {
                displayedMonth = newValue
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    Button(action: onShowNotifications) {
                        Image(systemName: "bell")
                    }
                    .accessibilityLabel("通知")
                    Button { showsUniversityConnection = true } label: {
                        Image(systemName: universityCalendarURL.isEmpty ? "link.badge.plus" : "link.circle.fill")
                    }
                    .accessibilityLabel("大学のカレンダー連携")
                    Button {
                        showsNewEvent = true
                    } label: {
                        Label("予定を追加", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showsNewEvent) {
            CalendarEventEditor(event: nil, initialDate: selectedDate)
        }
        .sheet(item: $editingEvent) { event in
            CalendarEventEditor(event: event, initialDate: event.startDate)
        }
        .sheet(isPresented: $showsUniversityConnection) {
            NavigationStack {
                Form {
                    Section {
                        SecureField("カレンダーURL", text: $universityCalendarURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("今すぐ同期", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await syncUniversityCalendar() }
                        }
                        .disabled(isUniversitySyncing || universityCalendarURL.isEmpty)
                        if isUniversitySyncing { ProgressView() }
                        if !universityStatus.isEmpty {
                            Text(universityStatus).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("カレンダーURL")
                    } footer: {
                        Text("在学中の大学のLMS（Moodleなど）で発行した購読用リンクを貼り付けてください。課題・小テスト・授業の期限を取り込みます。URLはこの端末の安全な領域に保存され、締切当日の朝8時に通知でお知らせします。")
                    }
                    if let detected = UniversityCalendar.universityName(forURL: universityCalendarURL) {
                        Section {
                            Label(detected, systemImage: "building.columns.fill")
                        } header: {
                            Text("認識された大学")
                        }
                    }
                    if !UniversityCalendar.loadURL().isEmpty {
                        Section {
                            Button("連携を解除", role: .destructive) {
                                UniversityCalendar.removeURL()
                                UniversityCalendar.storedName = nil
                                universityCalendarURL = ""
                                universityStatus = L("連携を解除しました。")
                                UniversityCalendar.cancelAllDeadlineNotifications()
                            }
                        }
                    }
                }
                .navigationTitle("大学連携")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") { showsUniversityConnection = false }
                    }
                }
            }
        }
    }

    @MainActor
    private func syncUniversityCalendar() async {
        isUniversitySyncing = true
        universityStatus = ""
        defer { isUniversitySyncing = false }
        do {
            let imported = try await UniversityCalendar.fetch(from: universityCalendarURL)
            let university = UniversityCalendar.displayName(forURL: universityCalendarURL)

            // Matches on the current key and on the one the Waseda-only build
            // wrote, so an existing calendar is updated rather than duplicated.
            var existing: [String: CalendarEvent] = [:]
            for event in events {
                guard event.externalSource == UniversityCalendar.externalSource
                        || event.externalSource == "waseda-moodle",
                      let id = event.externalID else { continue }
                existing[id] = event
            }

            let incomingIDs = Set(imported.map(\.id))
            for item in imported {
                let event = existing[item.id] ?? {
                    let created = CalendarEvent(title: item.title, startDate: item.startDate,
                                                endDate: item.endDate, kind: .other, notes: item.notes)
                    modelContext.insert(created)
                    return created
                }()
                event.title = item.title
                event.startDate = item.startDate
                event.endDate = item.endDate
                event.notes = item.notes
                event.externalID = item.id
                event.externalSource = UniversityCalendar.externalSource
                event.externalSourceName = university
            }
            for event in existing.values where !incomingIDs.contains(event.externalID ?? "") {
                EventReminderNotifications.cancel(for: event)
                modelContext.delete(event)
            }
            try modelContext.save()

            UniversityCalendar.saveURL(universityCalendarURL)
            UniversityCalendar.storedName = university
            await UniversityCalendar.requestNotificationPermission()
            await UniversityCalendar.scheduleDeadlineNotifications(for: imported, university: university)
            universityStatus = imported.isEmpty
                ? L("\(university)に接続しましたが、取り込める予定がありませんでした。")
                : L("\(university)の予定を\(imported.count)件同期しました。")
        } catch {
            universityStatus = error.localizedDescription
        }
    }

    private var calendarPanel: some View {
        ScrollView {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                learningMetric(
                    title: "今日の勉強時間",
                    value: formattedDuration(todayStudySeconds),
                    icon: "clock.fill",
                    color: .blue
                )
                learningMetric(
                    title: "連続学習日数",
                    value: "\(currentStudyStreak)日",
                    icon: "flame.fill",
                    color: .orange
                )
            }
            .padding(.horizontal)

            MonthCalendarGrid(
                selectedDate: $selectedDate,
                displayedMonth: $displayedMonth,
                eventKindsByDay: eventKindsByDay,
                colorFor: color(for:)
            )
                .padding(20)
                .background(.background, in: RoundedRectangle(cornerRadius: 24))
                .shadow(color: .indigo.opacity(0.10), radius: 14, y: 5)
                .padding()

            HStack(spacing: 14) {
                eventLegend(.test)
                eventLegend(.classLesson)
                eventLegend(.other)
            }
            .padding(.bottom, 12)
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            LinearGradient(
                colors: [Color.indigo.opacity(0.10), Color.cyan.opacity(0.07), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func learningMetric(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(color.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.bold()).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(color.opacity(0.18)))
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        return minutes >= 60
            ? L("\(minutes / 60)時間\(minutes % 60)分")
            : L("\(minutes)分")
    }

    private func eventLegend(_ kind: CalendarEventKind) -> some View {
        Label(kind.title, systemImage: kind.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color(for: kind))
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedDate.formatted(.dateTime.month().day().weekday(.wide)))
                        .font(.title3.bold())
                    Text("\(selectedDayEvents.count)件の予定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { showsNewEvent = true } label: {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
            }
            .padding()

            if selectedDayEvents.isEmpty {
                ContentUnavailableView(
                    "予定はありません",
                    systemImage: "calendar.badge.plus",
                    description: Text("＋からテストや授業の予定を追加できます")
                )
            } else {
                List {
                    ForEach(selectedDayEvents) { event in
                        // Deliberately not a `Button`: inside a `List` on
                        // iPad, a row `Button` needs one tap to give the row
                        // focus and a second to actually fire — the platform
                        // focus system treats the two as separate steps. A
                        // plain tap gesture on the row's own content fires
                        // immediately, matching a single tap.
                        HStack(spacing: 12) {
                            Image(systemName: event.kind.icon)
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(color(for: event.kind), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title).font(.headline)
                                Text(event.startDate.formatted(date: .omitted, time: .shortened)
                                     + "〜"
                                     + event.endDate.formatted(date: .omitted, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !event.notes.isEmpty {
                                    Text(event.notes).font(.caption).lineLimit(2)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editingEvent = event }
                        .swipeActions {
                            Button("削除", role: .destructive) {
                                EventReminderNotifications.cancel(for: event)
                                modelContext.delete(event)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(Color(.secondarySystemBackground))
    }

    private func color(for kind: CalendarEventKind) -> Color {
        switch kind {
        case .test: .red
        case .classLesson: .blue
        case .other: .orange
        }
    }
}

/// A month grid built from scratch rather than `DatePicker(.graphical)`,
/// which has no supported way to decorate individual days — there's no hook
/// to draw the "something is happening here" dot this view exists for.
private struct MonthCalendarGrid: View {
    @Binding var selectedDate: Date
    @Binding var displayedMonth: Date
    let eventKindsByDay: [Date: Set<CalendarEventKind>]
    let colorFor: (CalendarEventKind) -> Color

    private let calendar = Calendar.current
    /// Dot order matches the legend beneath the grid (test, class, other) so
    /// the same color always means the same thing.
    private let kindOrder: [CalendarEventKind] = [.test, .classLesson, .other]

    var body: some View {
        VStack(spacing: 14) {
            header
            weekdayHeader
            dayGrid
        }
    }

    private var header: some View {
        HStack {
            Button { shiftMonth(by: -1) } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 30, height: 30)
            }
            Spacer()
            Text(displayedMonth.formatted(.dateTime.year().month(.wide)))
                .font(.headline)
            Spacer()
            Button { shiftMonth(by: 1) } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 30, height: 30)
            }
        }
        .foregroundStyle(.indigo)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(calendar.veryShortWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var dayGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 6) {
            ForEach(daysToDisplay, id: \.self) { day in
                dayCell(day)
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let inDisplayedMonth = calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month)
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(day)
        let kinds = kindOrder.filter { (eventKindsByDay[calendar.startOfDay(for: day)] ?? []).contains($0) }

        return Button {
            selectedDate = day
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                    .foregroundStyle(
                        isSelected ? .white : (inDisplayedMonth ? .primary : .secondary.opacity(0.4))
                    )
                    .frame(width: 30, height: 30)
                    .background {
                        if isSelected {
                            Circle().fill(Color.indigo)
                        } else if isToday {
                            Circle().strokeBorder(Color.indigo, lineWidth: 1.5)
                        }
                    }

                HStack(spacing: 3) {
                    ForEach(kinds, id: \.self) { kind in
                        Circle().fill(colorFor(kind)).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Always 42 cells (6 full weeks) so the grid's height doesn't jump
    /// between months with four weeks and months with six.
    private var daysToDisplay: [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
              let gridStart = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start)?.start
        else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private func shiftMonth(by delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth) else { return }
        displayedMonth = next
    }
}

/// Per-event "coming up soon" reminders, distinct from
/// `UniversityCalendar`'s once-a-day deadline digest: each event gets its
/// own notification at a lead time the user picks when creating or editing
/// it, keyed by the event's own stable `id` so it can be rescheduled or
/// cancelled independently of every other event's reminder.
enum EventReminderNotifications {
    private static let identifierPrefix = "event-reminder-"

    static func schedule(for event: CalendarEvent) async {
        let identifier = identifierPrefix + event.id.uuidString
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        let option = EventReminderOption(minutesBefore: event.reminderMinutesBefore)
        guard option != .none else { return }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let fireDate = event.startDate.addingTimeInterval(-Double(option.rawValue) * 60)
        guard fireDate > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = L("もうすぐ予定です")
        content.body = L("\(event.title)・\(event.startDate.formatted(date: .omitted, time: .shortened))")
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
            repeats: false
        )
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }

    static func cancel(for event: CalendarEvent) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [identifierPrefix + event.id.uuidString]
        )
    }
}

private struct CalendarEventEditor: View {
    let event: CalendarEvent?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var kind: CalendarEventKind
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var notes: String
    @State private var reminderOption: EventReminderOption

    init(event: CalendarEvent?, initialDate: Date) {
        self.event = event
        let calendar = Calendar.current
        let defaultStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: initialDate) ?? initialDate
        _title = State(initialValue: event?.title ?? "")
        _kind = State(initialValue: event?.kind ?? .classLesson)
        _startDate = State(initialValue: event?.startDate ?? defaultStart)
        _endDate = State(initialValue: event?.endDate ?? defaultStart.addingTimeInterval(3600))
        _notes = State(initialValue: event?.notes ?? "")
        _reminderOption = State(initialValue: EventReminderOption(
            minutesBefore: event?.reminderMinutesBefore ?? EventReminderOption.thirtyMinutes.rawValue
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("予定") {
                    TextField("タイトル", text: $title)
                    Picker("種類", selection: $kind) {
                        ForEach(CalendarEventKind.allCases) { kind in
                            Label(kind.title, systemImage: kind.icon).tag(kind)
                        }
                    }
                }
                Section("日時") {
                    DatePicker("開始", selection: $startDate)
                    DatePicker("終了", selection: $endDate, in: startDate...)
                }
                Section("通知タイミング") {
                    Picker("通知タイミング", selection: $reminderOption) {
                        ForEach(EventReminderOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                }
                Section("メモ") {
                    TextField("教室、範囲、持ち物など", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(event == nil ? L("予定を追加") : L("予定を編集"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        let savedEvent: CalendarEvent
        if let event {
            event.title = cleanTitle
            event.kind = kind
            event.startDate = startDate
            event.endDate = endDate
            event.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            event.reminderMinutesBefore = reminderOption.rawValue
            savedEvent = event
        } else {
            let created = CalendarEvent(
                title: cleanTitle,
                startDate: startDate,
                endDate: endDate,
                kind: kind,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            created.reminderMinutesBefore = reminderOption.rawValue
            modelContext.insert(created)
            savedEvent = created
        }
        try? modelContext.save()
        Task {
            await UniversityCalendar.requestNotificationPermission()
            await EventReminderNotifications.schedule(for: savedEvent)
        }
        dismiss()
    }
}
