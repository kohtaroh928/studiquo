import SwiftUI
import SwiftData
import Security
import UIKit
import UserNotifications

struct CalendarHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CalendarEvent.startDate) private var events: [CalendarEvent]
    @State private var selectedDate = Date.now
    @State private var visibleMonth = Date.now
    @State private var showsNewEvent = false
    @State private var editingEvent: CalendarEvent?
    @State private var showsWasedaConnection = false
    @State private var wasedaCalendarURL = WasedaMoodleCalendar.loadSavedURL()
    @State private var wasedaStatus = ""
    @State private var isWasedaSyncing = false

    private var selectedDayEvents: [CalendarEvent] {
        events.filter { Calendar.current.isDate($0.startDate, inSameDayAs: selectedDate) }
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
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showsWasedaConnection = true
                } label: {
                    Label("大学サイトと連携", systemImage: "link.badge.plus")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showsNewEvent = true
                } label: {
                    Label("予定を追加", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showsNewEvent) {
            CalendarEventEditor(event: nil, initialDate: selectedDate)
        }
        .sheet(item: $editingEvent) { event in
            CalendarEventEditor(event: event, initialDate: event.startDate)
        }
        .sheet(isPresented: $showsWasedaConnection) {
            wasedaConnectionSheet
        }
    }

    private var wasedaConnectionSheet: some View {
        NavigationStack {
            Form {
                Section("早稲田Moodleカレンダー") {
                    Text("MoodleのカレンダーエクスポートURLを貼り付けると、課題・小テスト・予定をStudiquoのカレンダーに同期します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    SecureField("https://wsdmoodle.waseda.jp/calendar/export_execute.php?...", text: $wasedaCalendarURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        if let value = UIPasteboard.general.string {
                            wasedaCalendarURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Label("クリップボードから貼り付け", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        Task { await syncWasedaMoodle() }
                    } label: {
                        if isWasedaSyncing {
                            Label("同期中...", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("今すぐ同期", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isWasedaSyncing || wasedaCalendarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !wasedaStatus.isEmpty {
                    Section {
                        Text(wasedaStatus)
                            .font(.footnote)
                            .foregroundStyle(wasedaStatus.hasPrefix("同期できません") ? .red : .secondary)
                    }
                }

                if !WasedaMoodleCalendar.loadSavedURL().isEmpty {
                    Section {
                        Button("連携を解除", role: .destructive) {
                            WasedaMoodleCalendar.removeSavedURL()
                            wasedaCalendarURL = ""
                            wasedaStatus = "保存済みのカレンダーURLを削除しました。"
                        }
                    }
                }
            }
            .navigationTitle("大学サイト連携")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { showsWasedaConnection = false }
                }
            }
        }
    }

    private var calendarPanel: some View {
        VStack(spacing: 12) {
            StudiquoMonthCalendar(
                selectedDate: $selectedDate,
                visibleMonth: $visibleMonth,
                events: events,
                colorForKind: color(for:)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            LinearGradient(
                colors: [Color.indigo.opacity(0.10), Color.cyan.opacity(0.07), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func eventLegend(_ kind: CalendarEventKind) -> some View {
        Label(kind.title, systemImage: kind.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color(for: kind))
    }

    @MainActor
    private func syncWasedaMoodle() async {
        isWasedaSyncing = true
        wasedaStatus = "Moodleカレンダーを確認しています..."
        defer { isWasedaSyncing = false }

        do {
            let importedEvents = try await WasedaMoodleCalendar.fetchEvents(from: wasedaCalendarURL)
            let existingByExternalID = Dictionary(
                uniqueKeysWithValues: events.compactMap { event -> (String, CalendarEvent)? in
                    guard event.externalSource == WasedaMoodleCalendar.sourceID,
                          let externalID = event.externalID else { return nil }
                    return (externalID, event)
                }
            )

            for imported in importedEvents {
                if let event = existingByExternalID[imported.id] {
                    event.title = imported.title
                    event.startDate = imported.startDate
                    event.endDate = imported.endDate
                    event.kind = imported.kind
                    event.notes = imported.notes
                    event.externalSourceName = WasedaMoodleCalendar.sourceName
                    event.notificationsEnabled = true
                    if event.reminderMinutesBefore == 0 { event.reminderMinutesBefore = 30 }
                    CalendarNotificationScheduler.schedule(for: event)
                } else {
                    let event = CalendarEvent(
                        title: imported.title,
                        startDate: imported.startDate,
                        endDate: imported.endDate,
                        kind: imported.kind,
                        notes: imported.notes,
                        externalID: imported.id,
                        externalSource: WasedaMoodleCalendar.sourceID,
                        externalSourceName: WasedaMoodleCalendar.sourceName
                    )
                    modelContext.insert(event)
                    CalendarNotificationScheduler.schedule(for: event)
                }
            }

            try modelContext.save()
            try WasedaMoodleCalendar.saveURL(wasedaCalendarURL)
            wasedaStatus = "\(importedEvents.count)件の予定を同期しました。新しい課題がMoodleカレンダーに出ると、このURLから取り込めます。"
        } catch {
            wasedaStatus = "同期できませんでした：\(error.localizedDescription)"
        }
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
                        Button { editingEvent = event } label: {
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
                                    if let sourceName = event.externalSourceName {
                                        Label(sourceName, systemImage: "link")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    if event.notificationsEnabled {
                                        Label(reminderLabel(for: event), systemImage: "bell.fill")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("削除", role: .destructive) {
                                CalendarNotificationScheduler.cancel(for: event)
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

    private func reminderLabel(for event: CalendarEvent) -> String {
        if event.reminderMinutesBefore == 0 { return "開始時刻に通知" }
        if event.reminderMinutesBefore >= 1440 { return "\(event.reminderMinutesBefore / 1440)日前に通知" }
        if event.reminderMinutesBefore >= 60 { return "\(event.reminderMinutesBefore / 60)時間前に通知" }
        return "\(event.reminderMinutesBefore)分前に通知"
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
    @State private var notificationsEnabled: Bool
    @State private var reminderMinutesBefore: Int

    init(event: CalendarEvent?, initialDate: Date) {
        self.event = event
        let calendar = Calendar.current
        let defaultStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: initialDate) ?? initialDate
        _title = State(initialValue: event?.title ?? "")
        _kind = State(initialValue: event?.kind ?? .classLesson)
        _startDate = State(initialValue: event?.startDate ?? defaultStart)
        _endDate = State(initialValue: event?.endDate ?? defaultStart.addingTimeInterval(3600))
        _notes = State(initialValue: event?.notes ?? "")
        _notificationsEnabled = State(initialValue: event?.notificationsEnabled ?? true)
        _reminderMinutesBefore = State(initialValue: event?.reminderMinutesBefore ?? 30)
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
                Section {
                    Toggle("予定を通知", isOn: $notificationsEnabled)
                    if notificationsEnabled {
                        Picker("通知タイミング", selection: $reminderMinutesBefore) {
                            ForEach(EventReminderOption.allCases) { option in
                                Text(option.title).tag(option.minutesBefore)
                            }
                        }
                    }
                } header: {
                    Text("通知")
                } footer: {
                    Text("通知はiPadの通知許可が必要です。保存時に許可を確認します。")
                }
                Section("メモ") {
                    TextField("教室、範囲、持ち物など", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(event == nil ? "予定を追加" : "予定を編集")
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
        if let event {
            event.title = cleanTitle
            event.kind = kind
            event.startDate = startDate
            event.endDate = endDate
            event.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            event.notificationsEnabled = notificationsEnabled
            event.reminderMinutesBefore = reminderMinutesBefore
            CalendarNotificationScheduler.schedule(for: event)
        } else {
            let newEvent = CalendarEvent(
                title: cleanTitle,
                startDate: startDate,
                endDate: endDate,
                kind: kind,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                reminderMinutesBefore: reminderMinutesBefore,
                notificationsEnabled: notificationsEnabled
            )
            modelContext.insert(newEvent)
            CalendarNotificationScheduler.schedule(for: newEvent)
        }
        try? modelContext.save()
        dismiss()
    }
}

private struct StudiquoMonthCalendar: View {
    @Binding var selectedDate: Date
    @Binding var visibleMonth: Date
    let events: [CalendarEvent]
    let colorForKind: (CalendarEventKind) -> Color

    private let calendar = Calendar.current
    private let weekdaySymbols = Calendar.current.shortStandaloneWeekdaySymbols

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button {
                    moveMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 34, height: 34)
                }

                Spacer()

                Text(monthTitle)
                    .font(.title3.bold())

                Spacer()

                Button {
                    moveMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 34, height: 34)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 8) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                ForEach(monthDays, id: \.self) { date in
                    if let date {
                        dayButton(date)
                    } else {
                        Color.clear
                            .frame(height: 46)
                    }
                }
            }

            Button {
                selectedDate = .now
                visibleMonth = .now
            } label: {
                Label("今日へ戻る", systemImage: "calendar")
                    .font(.caption.weight(.semibold))
            }
        }
    }

    private var monthTitle: String {
        visibleMonth.formatted(.dateTime.year().month(.wide))
    }

    private var monthDays: [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: visibleMonth),
              let dayRange = calendar.range(of: .day, in: .month, for: visibleMonth) else { return [] }

        let firstWeekday = calendar.component(.weekday, from: monthInterval.start)
        var days = Array(repeating: Optional<Date>.none, count: max(0, firstWeekday - 1))
        days += dayRange.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: monthInterval.start)
        }.map(Optional.some)

        while days.count % 7 != 0 {
            days.append(nil)
        }
        return days
    }

    private func events(on date: Date) -> [CalendarEvent] {
        events.filter { calendar.isDate($0.startDate, inSameDayAs: date) }
    }

    private func dayButton(_ date: Date) -> some View {
        let dayEvents = events(on: date)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(date)

        return Button {
            selectedDate = date
        } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.subheadline.weight(isSelected || isToday ? .bold : .medium))
                    .foregroundStyle(isSelected ? .white : (isToday ? Color.accentColor : Color.primary))

                HStack(spacing: 2) {
                    ForEach(Array(dayEvents.prefix(3).enumerated()), id: \.offset) { _, event in
                        Circle()
                            .fill(colorForKind(event.kind))
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 7)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isToday && !isSelected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dayAccessibilityLabel(date, events: dayEvents))
    }

    private func dayAccessibilityLabel(_ date: Date, events: [CalendarEvent]) -> String {
        let dateText = date.formatted(.dateTime.month().day().weekday(.wide))
        return events.isEmpty ? "\(dateText)、予定なし" : "\(dateText)、\(events.count)件の予定"
    }

    private func moveMonth(by value: Int) {
        visibleMonth = calendar.date(byAdding: .month, value: value, to: visibleMonth) ?? visibleMonth
    }
}

private enum EventReminderOption: Int, CaseIterable, Identifiable {
    case atTime = 0
    case fiveMinutes = 5
    case tenMinutes = 10
    case thirtyMinutes = 30
    case oneHour = 60
    case oneDay = 1440

    var id: Int { rawValue }
    var minutesBefore: Int { rawValue }

    var title: String {
        switch self {
        case .atTime: "開始時刻"
        case .fiveMinutes: "5分前"
        case .tenMinutes: "10分前"
        case .thirtyMinutes: "30分前"
        case .oneHour: "1時間前"
        case .oneDay: "1日前"
        }
    }
}

enum CalendarNotificationScheduler {
    static func schedule(for event: CalendarEvent) {
        cancel(for: event)
        guard event.notificationsEnabled else { return }

        let fireDate = event.startDate.addingTimeInterval(TimeInterval(-event.reminderMinutesBefore * 60))
        guard fireDate > Date.now else { return }

        let identifier = event.notificationID ?? "calendar-event-\(UUID().uuidString)"
        event.notificationID = identifier
        let title = event.title
        let body = notificationBody(startDate: event.startDate, reminderMinutesBefore: event.reminderMinutesBefore)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request)
        }
    }

    static func cancel(for event: CalendarEvent) {
        guard let identifier = event.notificationID else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private static func notificationBody(startDate: Date, reminderMinutesBefore: Int) -> String {
        let time = startDate.formatted(date: .omitted, time: .shortened)
        if reminderMinutesBefore == 0 {
            return "\(time)から予定が始まります。"
        }
        return "\(reminderMinutesBefore)分後（\(time)）に予定があります。"
    }
}

private enum WasedaMoodleCalendar {
    static let sourceID = "waseda-moodle"
    static let sourceName = "早稲田Moodle"
    private static let keychainService = "com.yabuko.studiquo.waseda-moodle-calendar"
    private static let keychainAccount = "calendar-url"

    struct ImportedEvent {
        let id: String
        let title: String
        let startDate: Date
        let endDate: Date
        let kind: CalendarEventKind
        let notes: String
    }

    enum SyncError: LocalizedError {
        case invalidURL
        case invalidHost
        case downloadFailed(Int)
        case invalidCalendar

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                "MoodleのカレンダーURLを貼り付けてください。"
            case .invalidHost:
                "早稲田MoodleのカレンダーURLではないようです。"
            case .downloadFailed(let status):
                "Moodleから取得できませんでした（\(status)）。URLの期限やログイン状態を確認してください。"
            case .invalidCalendar:
                "カレンダー形式として読み取れませんでした。"
            }
        }
    }

    static func fetchEvents(from rawValue: String) async throws -> [ImportedEvent] {
        let url = try normalizedURL(from: rawValue)
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SyncError.downloadFailed(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS),
              text.contains("BEGIN:VCALENDAR") else {
            throw SyncError.invalidCalendar
        }
        return parseICalendar(text)
    }

    static func normalizedURL(from rawValue: String) throws -> URL {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("webcal://") {
            value = "https://" + value.dropFirst("webcal://".count)
        } else if value.hasPrefix("webcals://") {
            value = "https://" + value.dropFirst("webcals://".count)
        }

        guard let url = URL(string: value),
              let host = url.host?.lowercased(),
              ["wsdmoodle.waseda.jp", "moodle.waseda.jp"].contains(host) else {
            throw SyncError.invalidURL
        }
        guard url.path.contains("/calendar/") else { throw SyncError.invalidHost }
        return url
    }

    static func loadSavedURL() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func saveURL(_ rawValue: String) throws {
        let value = try normalizedURL(from: rawValue).absoluteString
        let data = Data(value.utf8)
        removeSavedURL()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess { throw SyncError.invalidURL }
    }

    static func removeSavedURL() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func parseICalendar(_ text: String) -> [ImportedEvent] {
        var unfolded: [String] = []
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t"), let last = unfolded.indices.last {
                unfolded[last] += String(rawLine.dropFirst())
            } else {
                unfolded.append(rawLine)
            }
        }

        var events: [ImportedEvent] = []
        var fields: [String: [String]] = [:]
        var insideEvent = false

        for line in unfolded {
            if line == "BEGIN:VEVENT" {
                fields = [:]
                insideEvent = true
            } else if line == "END:VEVENT" {
                if let event = makeEvent(from: fields) { events.append(event) }
                insideEvent = false
            } else if insideEvent, let separator = line.firstIndex(of: ":") {
                let key = String(line[..<separator]).split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
                let value = String(line[line.index(after: separator)...])
                fields[key, default: []].append(value)
            }
        }
        return events
    }

    private static func makeEvent(from fields: [String: [String]]) -> ImportedEvent? {
        guard let title = fields["SUMMARY"]?.first.map(unescape),
              let startRaw = fields["DTSTART"]?.first,
              let startDate = parseDate(startRaw) else { return nil }

        let endDate = fields["DTEND"]?.first.flatMap(parseDate) ?? startDate.addingTimeInterval(3600)
        let id = fields["UID"]?.first ?? "\(title)-\(startDate.timeIntervalSince1970)"
        let description = fields["DESCRIPTION"]?.first.map(unescape) ?? ""
        let location = fields["LOCATION"]?.first.map(unescape) ?? ""
        let notes = [description, location.isEmpty ? "" : "場所: \(location)"]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return ImportedEvent(
            id: id,
            title: title,
            startDate: startDate,
            endDate: max(endDate, startDate.addingTimeInterval(60)),
            kind: inferKind(title: title, notes: notes),
            notes: notes
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let formats = [
            "yyyyMMdd'T'HHmmss'Z'",
            "yyyyMMdd'T'HHmmss",
            "yyyyMMdd"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            formatter.timeZone = format.hasSuffix("'Z'") ? TimeZone(secondsFromGMT: 0) : .current
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static func inferKind(title: String, notes: String) -> CalendarEventKind {
        let value = "\(title)\n\(notes)".lowercased()
        if ["課題", "提出", "assignment", "レポート", "quiz", "小テスト", "exam", "試験", "テスト"].contains(where: value.contains) {
            return .test
        }
        if ["授業", "講義", "class", "lecture"].contains(where: value.contains) {
            return .classLesson
        }
        return .other
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
