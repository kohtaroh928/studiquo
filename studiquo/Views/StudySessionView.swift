import SwiftUI

struct StudySessionView: View {
    @Bindable var notebook: Notebook
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPageIndex = 0
    @State private var showsAnswer = false
    @State private var reviewWeakOnly = false
    @State private var remainingSeconds = 25 * 60
    @State private var timerIsRunning = false
    @State private var timer: Timer?

    private var cards: [NotePage] {
        notebook.sortedPages.filter {
            !$0.flashcardQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!reviewWeakOnly || $0.flashcardMastery < 2)
        }
    }

    private var currentCard: NotePage? {
        guard cards.indices.contains(selectedPageIndex) else { return nil }
        return cards[selectedPageIndex]
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                cardEditor
                    .frame(minWidth: 300, idealWidth: 380, maxWidth: 440)
                Divider()
                reviewArea
            }
            .navigationTitle("学習モード")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { timerControl }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    private var cardEditor: some View {
        List {
            Section("カードを作成") {
                ForEach(Array(notebook.sortedPages.enumerated()), id: \.element.persistentModelID) { index, page in
                    DisclosureGroup {
                        TextField("問題", text: Bindable(page).flashcardQuestion, axis: .vertical)
                        TextField("答え", text: Bindable(page).flashcardAnswer, axis: .vertical)
                        if page.flashcardQuestion.isEmpty {
                            Button("ページ名と認識文字から作る") {
                                page.flashcardQuestion = page.title.isEmpty ? "ページ \(index + 1) の要点は？" : page.title
                                page.flashcardAnswer = page.recognizedText
                            }
                        }
                    } label: {
                        HStack {
                            Text(page.title.isEmpty ? "ページ \(index + 1)" : page.title)
                            Spacer()
                            if !page.flashcardQuestion.isEmpty {
                                Image(systemName: "rectangle.on.rectangle.angled").foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
        }
    }

    private var reviewArea: some View {
        VStack(spacing: 18) {
            HStack {
                Toggle("苦手だけ", isOn: $reviewWeakOnly)
                    .toggleStyle(.button)
                Spacer()
                Text(cards.isEmpty ? "0 / 0" : "\(selectedPageIndex + 1) / \(cards.count)")
                    .font(.subheadline.monospacedDigit())
            }

            if let card = currentCard {
                VStack(spacing: 20) {
                    Text(card.flashcardQuestion)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Divider()
                    if showsAnswer {
                        Text(card.flashcardAnswer.isEmpty ? "答えが未入力です" : card.flashcardAnswer)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                    } else {
                        Button("答えを見る") { withAnimation { showsAnswer = true } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))

                if showsAnswer {
                    HStack {
                        scoreButton("もう一度", mastery: 0, color: .red)
                        scoreButton("難しい", mastery: 1, color: .orange)
                        scoreButton("覚えた", mastery: 2, color: .green)
                    }
                }
            } else {
                ContentUnavailableView("カードがありません", systemImage: "rectangle.on.rectangle.angled", description: Text("左側で問題と答えを登録してください"))
            }
        }
        .padding(24)
        .onChange(of: reviewWeakOnly) { _, _ in selectedPageIndex = 0; showsAnswer = false }
    }

    private func scoreButton(_ title: String, mastery: Int, color: Color) -> some View {
        Button(title) { score(mastery) }
            .buttonStyle(.borderedProminent)
            .tint(color)
    }

    private func score(_ mastery: Int) {
        guard let card = currentCard else { return }
        card.flashcardMastery = mastery
        card.flashcardReviewCount += 1
        card.flashcardLastReviewedAt = .now
        notebook.updatedAt = .now
        showsAnswer = false
        selectedPageIndex = cards.isEmpty ? 0 : (selectedPageIndex + 1) % cards.count
    }

    private var timerControl: some View {
        HStack {
            Text(String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60))
                .font(.body.monospacedDigit())
            Button(timerIsRunning ? "一時停止" : "開始") { toggleTimer() }
            Button("リセット") { resetTimer() }
        }
    }

    private func toggleTimer() {
        timerIsRunning.toggle()
        timer?.invalidate()
        guard timerIsRunning else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if remainingSeconds > 0 { remainingSeconds -= 1 }
            else { timerIsRunning = false; timer?.invalidate() }
        }
    }

    private func resetTimer() {
        timer?.invalidate()
        timerIsRunning = false
        remainingSeconds = 25 * 60
    }
}
