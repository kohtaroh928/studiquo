import SwiftUI
import SwiftData

/// The AI学習計画 flow: pick a test → pick the folder(s) its material lives
/// in → AI proposes a session-by-session schedule → the student picks which
/// sessions to actually keep, which are then written as ordinary
/// `CalendarEvent`s (`AIStudyPlanService.applySessions`).
struct AIStudyPlanFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CalendarEvent.startDate) private var allEvents: [CalendarEvent]
    @Query private var notebooks: [Notebook]
    @Query private var flashcardDecks: [FlashcardDeck]
    @Query private var textDocuments: [TextDocument]
    @AppStorage("libraryFolderNames") private var folderNamesStorage = ""

    @State private var selectedTest: CalendarEvent?
    @State private var selectedFolders: Set<String> = []
    @State private var isGenerating = false
    @State private var sessions: [AIStudyPlanResult.Session] = []
    @State private var selectedSessionIndices: Set<Int> = []
    @State private var errorMessage: String?
    @State private var didApply = false

    private var folderNames: [String] {
        folderNamesStorage.split(separator: "\n").map(String.init)
    }

    private var upcomingTests: [CalendarEvent] {
        allEvents.filter { $0.kind == .test && $0.startDate > .now }.sorted { $0.startDate < $1.startDate }
    }

    var body: some View {
        NavigationStack {
            Group {
                if didApply {
                    completionView
                } else if isGenerating {
                    ProgressView(L("計画を作成しています…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !sessions.isEmpty {
                    previewView
                } else if let test = selectedTest {
                    folderSelectionView(for: test)
                } else {
                    testSelectionView
                }
            }
            .navigationTitle(L("AI学習計画"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("閉じる")) { dismiss() }
                }
                if selectedTest != nil && sessions.isEmpty && !didApply {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(L("戻る")) { selectedTest = nil; selectedFolders = [] }
                    }
                }
            }
            .alert(L("エラー"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in if !isPresented { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: Step 1 — pick a test

    private var testSelectionView: some View {
        Group {
            if upcomingTests.isEmpty {
                ContentUnavailableView(
                    L("近日中のテスト予定がありません"),
                    systemImage: "pencil.and.list.clipboard",
                    description: Text(L("先にカレンダーでテストの予定を追加してください。"))
                )
            } else {
                List(upcomingTests) { test in
                    Button {
                        selectedTest = test
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(test.title).font(.headline)
                            Text(test.startDate.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    // MARK: Step 2 — pick the relevant folder(s)

    private func folderSelectionView(for test: CalendarEvent) -> some View {
        List {
            if folderNames.isEmpty {
                ContentUnavailableView(
                    L("フォルダがありません"),
                    systemImage: "folder",
                    description: Text(L("先にノートや暗記デッキをフォルダにまとめてください。"))
                )
            } else {
                Section {
                    ForEach(folderNames, id: \.self) { folder in
                        Button {
                            if selectedFolders.contains(folder) { selectedFolders.remove(folder) }
                            else { selectedFolders.insert(folder) }
                        } label: {
                            HStack {
                                Text(folder)
                                Spacer()
                                if selectedFolders.contains(folder) {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text(L("「\(test.title)」の範囲のフォルダを選んでください"))
                } footer: {
                    Text(L("選んだフォルダの中のノート・暗記デッキ・文書の内容や成績がAIに送られ、学習計画が作られます。ロックされたノートは含まれません。"))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await generate(for: test) }
            } label: {
                Label(L("学習計画を作成"), systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedFolders.isEmpty)
            .padding()
            .background(.bar)
        }
    }

    private func generate(for test: CalendarEvent) async {
        isGenerating = true
        defer { isGenerating = false }
        let request = AIStudyPlanService.makeRequest(
            test: test,
            selectedFolders: Array(selectedFolders),
            notebooks: notebooks,
            flashcardDecks: flashcardDecks,
            textDocuments: textDocuments,
            calendarEvents: allEvents
        )
        do {
            let result = try await AIStudyPlanService.generatePlan(for: request)
            if result.sessions.isEmpty {
                errorMessage = L("学習計画を作成できませんでした。選んだフォルダの内容が少ないか、AIが十分な材料を見つけられませんでした。")
            } else {
                sessions = result.sessions
                selectedSessionIndices = Set(result.sessions.indices)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Step 3 — preview and confirm

    private var previewView: some View {
        List {
            Section {
                ForEach(Array(sessions.enumerated()), id: \.offset) { index, session in
                    Button {
                        if selectedSessionIndices.contains(index) { selectedSessionIndices.remove(index) }
                        else { selectedSessionIndices.insert(index) }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: selectedSessionIndices.contains(index) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedSessionIndices.contains(index) ? Color.accentColor : .secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(session.date) \(session.startTime)〜（\(session.durationMinutes)分）")
                                    .font(.subheadline.weight(.semibold))
                                Text(session.focus).font(.body)
                                Text(session.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } footer: {
                Text(L("内容を確認し、追加したいセッションだけチェックしてください。日時や時間はあとからカレンダーで編集できます。"))
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await applySelected() }
            } label: {
                Label(L("カレンダーに追加（\(selectedSessionIndices.count)件）"), systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedSessionIndices.isEmpty)
            .padding()
            .background(.bar)
        }
    }

    private func applySelected() async {
        guard let test = selectedTest else { return }
        let chosen = selectedSessionIndices.sorted().map { sessions[$0] }
        await AIStudyPlanService.applySessions(chosen, test: test, modelContext: modelContext)
        didApply = true
    }

    // MARK: Step 4 — done

    private var completionView: some View {
        ContentUnavailableView {
            Label(L("計画をカレンダーに追加しました"), systemImage: "checkmark.circle.fill")
        } description: {
            Text(L("カレンダーから内容を確認・編集できます。"))
        } actions: {
            Button(L("閉じる")) { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }
}
