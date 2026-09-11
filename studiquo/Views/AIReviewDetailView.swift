import SwiftUI
import UniformTypeIdentifiers

/// Opened from a "復習の時間です" notification or bell-feed row. Shows the
/// explanation the AI researched the day the question was asked, with a way
/// to save/share it as a PDF and, only if the student chooses, a short quiz.
///
/// The explanation itself already lives as a `TextDocument` in the student's
/// own 文書 library (`AIReviewService` files it under "AI復習") — this screen
/// is a convenient way to read it right after the notification, not the only
/// place it can be opened from.
struct AIReviewDetailView: View {
    let item: AIReviewItem
    @Environment(\.dismiss) private var dismiss
    @State private var showsQuiz = false
    @State private var pdfDocument: PDFExportDocument?
    @State private var showsPDFExporter = false

    private var explanationText: AttributedString {
        if let document = item.explanationDocument {
            return AttributedString(DocumentBody.decode(document.bodyData))
        }
        return AttributedString(item.explanationMarkdown)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(L("昨日の質問"), systemImage: "bubble.left.and.bubble.right.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.purple)
                        Text(item.questionText)
                            .font(.title3.bold())
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))

                    Text(explanationText)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if !item.quiz.isEmpty {
                        Button {
                            showsQuiz = true
                        } label: {
                            Label(L("クイズを受ける（\(item.quiz.count)問）"), systemImage: "questionmark.circle.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    }

                    Button {
                        exportPDF()
                    } label: {
                        Label(L("PDFとして保存・共有"), systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .disabled(item.explanationDocument == nil)
                }
                .padding(20)
            }
            .navigationTitle(L("復習"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("閉じる")) { dismiss() }
                }
            }
        }
        .modifier(PDFSaveModifier(
            isPresented: $showsPDFExporter,
            document: $pdfDocument,
            filename: item.explanationDocument?.title ?? L("復習")
        ))
        .fullScreenCover(isPresented: $showsQuiz) {
            AIReviewQuizView(questions: item.quiz)
        }
    }

    private func exportPDF() {
        guard let document = item.explanationDocument,
              let data = ExportService.pdfData(from: document) else { return }
        pdfDocument = PDFExportDocument(data: data)
        showsPDFExporter = true
    }
}

/// The percentage shown on the quiz results ring. A free function (rather
/// than kept inline as `AIReviewQuizView.percentage`'s only expression) so
/// its rounding and zero-question guard are unit tested directly.
func quizScorePercentage(correct: Int, total: Int) -> Int {
    guard total > 0 else { return 0 }
    return Int((Double(correct) / Double(total) * 100).rounded())
}

/// A short, ungraded-beyond-this-session quiz built from `AIQuizQuestion`s —
/// deliberately not tied to `FlashcardDeck`, since these questions are
/// generated once for a single review and aren't meant to be a persistent
/// deck the student manages.
struct AIReviewQuizView: View {
    let questions: [AIQuizQuestion]
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var showsAnswer = false
    @State private var correctCount = 0

    private enum Phase { case studying, results }
    @State private var phase: Phase = .studying

    private var percentage: Int {
        quizScorePercentage(correct: correctCount, total: questions.count)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .studying: studyView
                case .results: resultsView
                }
            }
            .navigationTitle(L("確認クイズ"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("閉じる")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var studyView: some View {
        if questions.indices.contains(index) {
            let question = questions[index]
            VStack(spacing: 16) {
                HStack {
                    Text("\(index + 1) / \(questions.count)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                    ProgressView(value: Double(index), total: Double(max(questions.count, 1)))
                        .tint(.purple)
                }

                VStack(spacing: 20) {
                    Text(showsAnswer ? question.answer : question.question)
                        .font(showsAnswer ? .title3 : .title2.bold())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(showsAnswer ? .purple : .primary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background, in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.purple.opacity(0.22), lineWidth: 2))
                .contentShape(RoundedRectangle(cornerRadius: 24))
                .onTapGesture { showsAnswer.toggle() }

                if showsAnswer {
                    HStack(spacing: 12) {
                        gradeButton(L("不正解"), icon: "xmark", color: .red) { grade(correct: false) }
                        gradeButton(L("正解"), icon: "checkmark", color: .green) { grade(correct: true) }
                    }
                } else {
                    Button(L("答えを見る")) { showsAnswer = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
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

    private func grade(correct: Bool) {
        if correct { correctCount += 1 }
        if index + 1 < questions.count {
            index += 1
            showsAnswer = false
        } else {
            phase = .results
        }
    }

    private var resultsView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.16), lineWidth: 18)
                Circle()
                    .trim(from: 0, to: CGFloat(percentage) / 100)
                    .stroke(
                        percentage == 100 ? Color.green : Color.purple,
                        style: StrokeStyle(lineWidth: 18, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text("\(percentage)%")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(percentage == 100 ? .green : .purple)
            }
            .frame(width: 190, height: 190)

            Text(L("全 \(questions.count) 問中 \(correctCount) 問正解"))
                .font(.title3.bold())

            Button(L("閉じる")) { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
