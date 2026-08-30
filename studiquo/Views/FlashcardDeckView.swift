import SwiftUI
import SwiftData

/// The full-screen counterpart to `ProtectedNotebookView`: shown in
/// `ContentView`'s detail pane, below the same tab bar notebooks use, when a
/// deck is selected from Home. Unlike a notebook's editor it has no ink
/// canvas anywhere in its view tree, so the drawing toolbar simply never
/// applies here — there is nothing to wire a "disable drawing" flag into.
struct FlashcardDeckView: View {
    @Bindable var deck: FlashcardDeck
    var onHome: () -> Void = {}
    @State private var mode: Mode = .edit

    private enum Mode: String, CaseIterable, Identifiable {
        case edit = "カード作成"
        case study = "暗記する"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: onHome) {
                    Label("ホームへ戻る", systemImage: "house.fill")
                }
                .buttonStyle(.plain)
                Divider().frame(height: 20)
                Label(deck.title, systemImage: "rectangle.on.rectangle.angled")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.bar)
            Divider()

            Picker("モード", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            if mode == .edit { editor }
            else { study }
        }
    }

    private var editor: some View {
        FlashcardEditorContent(deck: deck)
    }

    private var study: some View {
        FlashcardStudyContent(deck: deck, onHome: onHome)
    }
}

/// One study flow shared by the full-screen deck and split-pane deck.
struct FlashcardStudyContent: View {
    @Bindable var deck: FlashcardDeck
    var onHome: () -> Void = {}
    @State private var phase: Phase = .setup
    @State private var cards: [Flashcard] = []
    @State private var index = 0
    @State private var showsAnswer = false
    @State private var correctCount = 0
    @State private var incorrectCards: [Flashcard] = []
    @State private var visibleIncorrectCount = 10
    @StateObject private var adGate = InterstitialAdGate.shared

    private enum Phase: Equatable { case setup, studying, results }

    private var percentage: Int {
        guard !cards.isEmpty else { return 0 }
        return Int((Double(correctCount) / Double(cards.count) * 100).rounded())
    }

    var body: some View {
        Group {
            switch phase {
            case .setup: setupView
            case .studying: studyView
            case .results: resultsView
            }
        }
        .animation(.easeInOut(duration: 0.22), value: phase)
        .background(
            LinearGradient(
                colors: [Color.indigo.opacity(0.10), Color.cyan.opacity(0.06), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .fullScreenCover(isPresented: $adGate.isShowingAd) {
            InterstitialAdPlaceholder { adGate.dismiss() }
        }
    }

    private var setupView: some View {
        ScrollView {
            VStack(spacing: 18) {
                Button(action: startStudy) {
                    Label("スタート", systemImage: "play.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(deck.cards.isEmpty)

                studySetting(
                    title: "出題順",
                    icon: "shuffle",
                    color: .purple
                ) {
                    Picker("出題順", selection: Binding(
                        get: { deck.orderMode },
                        set: { deck.orderMode = $0; deck.updatedAt = .now }
                    )) {
                        Text("作成順").tag(FlashcardOrderMode.creation)
                        Text("ランダム").tag(FlashcardOrderMode.random)
                    }
                    .pickerStyle(.segmented)
                }

                studySetting(
                    title: "出題方向",
                    icon: "arrow.left.arrow.right",
                    color: .teal
                ) {
                    Picker("出題方向", selection: $deck.reversesQuestionAndAnswer) {
                        Text("問題 → 答え").tag(false)
                        Text("答え → 問題").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                if deck.cards.isEmpty {
                    Label("先に暗記カードを作成してください", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                } else {
                    HStack(spacing: 10) {
                        deckStat("カード数", "\(deck.cards.count)", "rectangle.stack", .indigo)
                        deckStat("学習回数", "\(deck.studySessionCount)", "arrow.triangle.2.circlepath", .teal)
                        deckStat("平均正解率", deck.accuracyText, "target", accuracyColor)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
    }

    /// Colour-codes the average so a weak deck is obvious at a glance.
    private var accuracyColor: Color {
        guard let accuracy = deck.averageAccuracy else { return .secondary }
        if accuracy >= 80 { return .green }
        if accuracy >= 50 { return .orange }
        return .red
    }

    private func deckStat(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(color)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }

    private func studySetting<Content: View>(
        title: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(color)
            content()
        }
        .padding(16)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(color.opacity(0.24)))
    }

    @ViewBuilder
    private var studyView: some View {
        if cards.indices.contains(index) {
            let card = cards[index]
            VStack(spacing: 16) {
                HStack {
                    Text("\(index + 1) / \(cards.count)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                    ProgressView(value: Double(index), total: Double(max(cards.count, 1)))
                        .tint(.indigo)
                }

                VStack(spacing: 20) {
                    Text(deck.reversesQuestionAndAnswer ? card.answer : card.question)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    if showsAnswer {
                        Divider()
                        Text(deck.reversesQuestionAndAnswer ? card.question : card.answer)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.teal)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background, in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.indigo.opacity(0.22), lineWidth: 2))
                .shadow(color: .indigo.opacity(0.12), radius: 14, y: 6)

                if showsAnswer {
                    HStack(spacing: 12) {
                        gradeButton("不正解", icon: "xmark", color: .red) { grade(correct: false) }
                        gradeButton("正解", icon: "checkmark", color: .green) { grade(correct: true) }
                    }
                } else {
                    Button("答えを見る", systemImage: "eye.fill") {
                        withAnimation { showsAnswer = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .controlSize(.large)
                }
            }
            .padding(18)
        }
    }

    private func gradeButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
    }

    private var resultsView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("学習結果").font(.title.bold())
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.16), lineWidth: 18)
                    Circle()
                        .trim(from: 0, to: CGFloat(percentage) / 100)
                        .stroke(
                            percentage == 100 ? Color.green : Color.indigo,
                            style: StrokeStyle(lineWidth: 18, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Text("\(percentage)%")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(percentage == 100 ? .green : .indigo)
                }
                .frame(width: 190, height: 190)

                Text("全 \(cards.count) 問中 \(correctCount) 問正解")
                    .font(.title3.bold())

                if incorrectCards.isEmpty {
                    Label("全問正解です！", systemImage: "party.popper.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("間違えたカード", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        ForEach(Array(incorrectCards.prefix(visibleIncorrectCount).enumerated()), id: \.element.persistentModelID) { offset, card in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(offset + 1). \(card.question)").font(.headline)
                                Text(card.answer).foregroundStyle(.secondary)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                        }
                        if visibleIncorrectCount < incorrectCards.count {
                            Button("さらに表示", systemImage: "chevron.down") {
                                visibleIncorrectCount += 10
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: 700)
                }

                VStack(spacing: 12) {
                    Button("ホームに戻る", systemImage: "house.fill", action: onHome)
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                    HStack(spacing: 12) {
                        Button("全て", systemImage: "rectangle.stack.fill") {
                            startStudy(with: deck.sortedCards)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        Button("間違いのみ", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90") {
                            startStudy(with: incorrectCards)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(incorrectCards.isEmpty)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func startStudy() {
        let ordered = deck.orderMode == .random ? deck.sortedCards.shuffled() : deck.sortedCards
        startStudy(with: ordered)
    }

    private func startStudy(with source: [Flashcard]) {
        cards = source
        guard !cards.isEmpty else { return }
        index = 0
        showsAnswer = false
        correctCount = 0
        incorrectCards = []
        visibleIncorrectCount = 10
        phase = .studying
    }

    private func grade(correct: Bool) {
        guard cards.indices.contains(index) else { return }
        let card = cards[index]
        card.reviewCount += 1
        card.lastReviewedAt = .now
        deck.totalAnswered += 1
        if correct {
            correctCount += 1
            card.mastery += 1
            deck.totalCorrect += 1
        } else {
            incorrectCards.append(card)
            card.mastery = max(0, card.mastery - 1)
        }
        deck.updatedAt = .now
        deck.lastStudiedAt = .now
        if index + 1 < cards.count {
            index += 1
            showsAnswer = false
        } else {
            deck.studySessionCount += 1
            phase = .results
            // Every second completed pass earns an interstitial. Counted here
            // rather than on entering the deck so a pass that is abandoned
            // half-way never triggers one.
            adGate.registerCompletedPass()
        }
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
    @State private var questionDropFrame: CGRect = .zero
    @State private var answerDropFrame: CGRect = .zero

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
        .onReceive(NotificationCenter.default.publisher(for: .studiquoSelectionDropped)) { notification in
            guard let drop = notification.object as? StudiquoSelectionDrop else { return }
            if questionDropFrame.contains(drop.screenPoint) {
                _ = appendRecognizedText(drop.text, to: &question)
            } else if answerDropFrame.contains(drop.screenPoint) {
                _ = appendRecognizedText(drop.text, to: &answer)
            }
        }
    }

    private var cardForm: some View {
        Form {
            Section("新規暗記カード") {
                TextField("問題", text: $question, axis: .vertical)
                    .lineLimit(3...8)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { frame in
                        questionDropFrame = frame
                    }
                    .dropDestination(for: String.self) { items, _ in
                        appendRecognizedText(items.first, to: &question)
                    }
                TextField("答え", text: $answer, axis: .vertical)
                    .lineLimit(3...8)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { frame in
                        answerDropFrame = frame
                    }
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
