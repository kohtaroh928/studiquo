import SwiftUI
import SwiftData

struct CalendarHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CalendarEvent.startDate) private var events: [CalendarEvent]
    @State private var selectedDate = Date.now
    @State private var showsNewEvent = false
    @State private var editingEvent: CalendarEvent?

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
    }

    private var calendarPanel: some View {
        VStack(spacing: 12) {
            DatePicker("日付", selection: $selectedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(.indigo)
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
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("削除", role: .destructive) { modelContext.delete(event) }
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

private struct CalendarEventEditor: View {
    let event: CalendarEvent?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var kind: CalendarEventKind
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var notes: String

    init(event: CalendarEvent?, initialDate: Date) {
        self.event = event
        let calendar = Calendar.current
        let defaultStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: initialDate) ?? initialDate
        _title = State(initialValue: event?.title ?? "")
        _kind = State(initialValue: event?.kind ?? .classLesson)
        _startDate = State(initialValue: event?.startDate ?? defaultStart)
        _endDate = State(initialValue: event?.endDate ?? defaultStart.addingTimeInterval(3600))
        _notes = State(initialValue: event?.notes ?? "")
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
        } else {
            modelContext.insert(CalendarEvent(
                title: cleanTitle,
                startDate: startDate,
                endDate: endDate,
                kind: kind,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        try? modelContext.save()
        dismiss()
    }
}
