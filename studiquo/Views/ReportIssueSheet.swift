import SwiftUI
import UIKit

/// Renders whatever's currently on screen into an image — used to capture
/// the reporter's bug at the moment they tap the megaphone button, before
/// ReportIssueSheet itself covers the screen.
enum ScreenshotCapture {
    @MainActor
    static func captureFrontWindow() -> UIImage? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        // Prefer the actual key window, but a window scene can briefly report
        // none as key (e.g. right as a toolbar button's own tap is handled) —
        // falling back to the frontmost window still captures the right
        // screen rather than silently reporting no screenshot at all.
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.last else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }
}

/// Carries "the report sheet should open" and "here's the screenshot it
/// should show" as one piece of state, for `.sheet(item:)`. A separate
/// `Bool` + `UIImage?` pair — set in the same button action, one right after
/// the other — isn't reliably read by a `.sheet(isPresented:)` closure by
/// the time it actually builds the sheet's content; bundling them into a
/// single value presented with `.sheet(item:)` (the same pattern this
/// codebase already uses for `editingEvent`/`previewURL`/etc.) sidesteps
/// that entirely.
struct PendingIssueReport: Identifiable {
    let id = UUID()
    let screenshot: UIImage?
}

/// The megaphone toolbar button every home screen (notes/カレンダー/フレンド)
/// carries, modelled on TestFlight's shake-to-report. Deliberately stateless
/// — the caller owns the `PendingIssueReport?` this sets and presents via
/// `.sheet(item:)`.
struct ReportIssueButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("問題を報告", systemImage: "megaphone")
        }
        .accessibilityLabel("問題を報告")
    }
}

/// What tapping the megaphone opens: a short description field and, if a
/// screenshot was captured, an opt-in preview of it. The toggle defaults off
/// — a friend's chat message or private note content can be on screen at
/// capture time, so it's shown to the reporter and only sent if they
/// explicitly choose to include it, rather than attached automatically the
/// way a shake-to-report SDK like Instabug would.
struct ReportIssueSheet: View {
    let capturedScreenshot: UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var attachScreenshot = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didSubmit = false

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $description)
                        .frame(minHeight: 120)
                } header: {
                    Text("何が起きましたか？")
                } footer: {
                    Text("操作の手順や、いつから起きているかを書いていただけると助かります。")
                }

                if let capturedScreenshot {
                    Section {
                        Toggle("今の画面を報告に添付する", isOn: $attachScreenshot)
                        if attachScreenshot {
                            Image(uiImage: capturedScreenshot)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
                        }
                    } footer: {
                        Text("フレンドとのチャットなど、他の人に関わる内容が写っていないか送る前にご確認ください。")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("問題を報告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("送信") { submit() }
                            .disabled(trimmedDescription.isEmpty)
                    }
                }
            }
            .alert("送信しました", isPresented: $didSubmit) {
                Button("閉じる") { dismiss() }
            } message: {
                Text("報告ありがとうございます。運営が確認します。")
            }
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    private func submit() {
        let text = trimmedDescription
        guard !text.isEmpty else { return }
        isSubmitting = true
        errorMessage = nil

        let screenshotPayload: (data: Data, contentType: String)?
        if attachScreenshot, let capturedScreenshot, let jpeg = capturedScreenshot.jpegData(compressionQuality: 0.6) {
            screenshotPayload = (jpeg, "image/jpeg")
        } else {
            screenshotPayload = nil
        }

        Task {
            do {
                _ = try await IssueReportService.submit(description: text, screenshot: screenshotPayload)
                await MainActor.run {
                    isSubmitting = false
                    didSubmit = true
                }
            } catch is IssueReportService.RateLimitedError {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = "送信が多すぎます。少し時間をおいてからもう一度お試しください。"
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = "送信できませんでした。しばらくしてからもう一度お試しください。"
                }
            }
        }
    }
}
