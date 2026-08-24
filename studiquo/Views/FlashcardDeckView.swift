import SwiftUI
import SwiftData

struct FlashcardDeckView: View {
    @Bindable var deck: FlashcardDeck
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .edit
    @State private var studyCards: [Flashcard] = []
    @State private var studyIndex = 0
    @State private var showsAnswer = false

    private enum Mode: String, CaseIterable, Identifiable {
        case edit = "カード作成"
        case study = "暗記する"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("モード", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                if mode == .edit { editor }
                else { study }
            }
            .navigationTitle(deck.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
        }
        .onAppear(perform: prepareStudy)
        .onChange(of: mode) { _, value in if value == .study { prepareStudy() } }
        .onChange(of: deck.orderModeRawValue) { _, _ in prepareStudy() }
    }

    private var editor: some View {
        FlashcardEditorContent(deck: deck)
    }

    private var study: some View {
        VStack(spacing: 18) {
            HStack(spacing: 18) {
                Toggle("答えを問題として出す", isOn: $deck.reversesQuestionAndAnswer)
                Picker("出題順", selection: Binding(
                    get: { deck.orderMode },
                    set: { deck.orderMode = $0; deck.updatedAt = .now }
                )) {
                    ForEach(FlashcardOrderMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                Button("最初から") { prepareStudy() }
            }
            .padding(.horizontal)

            if studyCards.indices.contains(studyIndex) {
                let card = studyCards[studyIndex]
                VStack(spacing: 24) {
                    Text(deck.reversesQuestionAndAnswer ? card.answer : card.question)
                        .font(.largeTitle.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Divider()
                    if showsAnswer {
                        Text(deck.reversesQuestionAndAnswer ? card.question : card.answer)
                            .font(.title2)
                            .multilineTextAlignment(.center)
                    } else {
                        Button("答えを見る") { withAnimation { showsAnswer = true } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(36)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal, 30)

                HStack {
                    Button("前へ", systemImage: "chevron.left") { moveStudy(by: -1) }
                        .disabled(studyIndex == 0)
                    Spacer()
                    Text("\(studyIndex + 1) / \(studyCards.count)").font(.body.monospacedDigit())
                    Spacer()
                    Button("次へ", systemImage: "chevron.right") { moveStudy(by: 1) }
                        .disabled(studyIndex >= studyCards.count - 1)
                }
                .padding()
            } else {
                ContentUnavailableView("カードがありません", systemImage: "rectangle.on.rectangle.angled", description: Text("カード作成から問題と答えを登録してください"))
            }
        }
    }

    private func prepareStudy() {
        studyCards = deck.orderMode == .random ? deck.sortedCards.shuffled() : deck.sortedCards
        studyIndex = 0
        showsAnswer = false
    }

    private func moveStudy(by amount: Int) {
        studyIndex = min(max(0, studyIndex + amount), max(0, studyCards.count - 1))
        showsAnswer = false
    }
}

/// Shared by the full-screen deck opened from Home and by a deck shown in a
/// split pane, keeping card creation behavior identical in both places.
struct FlashcardEditorContent: View {
    @Bindable var deck: FlashcardDeck
    @Environment(\.modelContext) private var modelContext
    @State private var question = ""
    @State private var answer = ""
    @State private var editingCard: Flashcard?

    private var canCreateCard: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 700 {
                HStack(spacing: 0) {
                    cardForm.frame(minWidth: 320, idealWidth: 420)
                    Divider()
                    cardList
                }
            } else {
                // A split pane is roughly half the screen width. Stacking the
                // same form and list keeps every control inside that pane
                // instead of forcing the full-screen two-column layout to
                // overflow into the neighboring notebook.
                VStack(spacing: 0) {
                    cardForm.frame(height: max(250, geometry.size.height * 0.52))
                    Divider()
                    cardList
                }
            }
        }
        .sheet(item: $editingCard) { card in
            FlashcardEditView(card: card) { deck.updatedAt = .now }
        }
    }

    private var cardForm: some View {
        Form {
            Section("新規暗記カード") {
                TextField("問題", text: $question, axis: .vertical)
                    .lineLimit(3...8)
                    .dropDestination(for: String.self) { items, _ in
                        appendRecognizedText(items.first, to: &question)
                    }
                TextField("答え", text: $answer, axis: .vertical)
                    .lineLimit(3...8)
                    .dropDestination(for: String.self) { items, _ in
                        appendRecognizedText(items.first, to: &answer)
                    }
                Button("このカードを保存して次へ", action: createCard)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreateCard)
                if !canCreateCard && (!question.isEmpty || !answer.isEmpty) {
                    Text("問題と答えの両方を入力すると、次のカードを作れます。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var cardList: some View {
        List {
            Section("作成済みカード（\(deck.cards.count)枚）") {
                ForEach(Array(deck.sortedCards.enumerated()), id: \.element.persistentModelID) { index, card in
                    Button { editingCard = card } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(index + 1). \(card.question)").font(.headline).lineLimit(2)
                            Text(card.answer).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("削除", role: .destructive) { delete(card) }
                    }
                }
                .onMove(perform: moveCards)
            }
        }
    }

    private func createCard() {
        guard canCreateCard else { return }
        let card = Flashcard(
            question: question.trimmingCharacters(in: .whitespacesAndNewlines),
            answer: answer.trimmingCharacters(in: .whitespacesAndNewlines),
            order: deck.cards.count
        )
        card.deck = deck
        deck.cards.append(card)
        deck.updatedAt = .now
        modelContext.insert(card)
        question = ""
        answer = ""
    }

    private func appendRecognizedText(_ text: String?, to field: inout String) -> Bool {
        guard let text else { return false }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if !field.isEmpty, !field.hasSuffix("\n") { field += "\n" }
        field += value
        return true
    }

    private func delete(_ card: Flashcard) {
        deck.cards.removeAll { $0 === card }
        modelContext.delete(card)
        reorderCards()
    }

    private func moveCards(from offsets: IndexSet, to destination: Int) {
        var cards = deck.sortedCards
        cards.move(fromOffsets: offsets, toOffset: destination)
        for (index, card) in cards.enumerated() { card.order = index }
        deck.updatedAt = .now
    }

    private func reorderCards() {
        for (index, card) in deck.sortedCards.enumerated() { card.order = index }
        deck.updatedAt = .now
    }

}

private struct FlashcardEditView: View {
    @Bindable var card: Flashcard
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answer = ""

    private var canSave: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("問題", text: $question, axis: .vertical)
                TextField("答え", text: $answer, axis: .vertical)
            }
            .navigationTitle("カードを編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        card.question = question.trimmingCharacters(in: .whitespacesAndNewlines)
                        card.answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave()
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .onAppear { question = card.question; answer = card.answer }
    }
}
