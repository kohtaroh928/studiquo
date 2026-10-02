import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers
import VisionKit
import Speech
import AVFoundation

/// The width of the chat pane, read so a narrow pane can start with its
/// history folded away. Reads the pane's own size, which nothing inside the
/// pane changes, so it cannot feed back into itself.
private struct AIChatPaneWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The AIトーク screen wired to the shared `AIChatStore`.
///
/// This is what each host puts on screen — the note editor's split pane and
/// floating panel, and the home AI tab — so they all show the same
/// conversations, drafts and "replying" state. A host passes only what is
/// specific to it: the editor adds the text of the page being read and the
/// pane-switching and paste-onto-page behaviour; the home screen adds none of
/// that and none of those menu items appear.
struct AIChatPanel: View {
    @ObservedObject var store: AIChatStore
    /// Text of whatever the student is looking at, sent with each message.
    var noteContext: () -> String = { "" }
    var onInsertAssistantMessage: ((String) -> Void)? = nil
    var onAttachDroppedTab: ((String) -> AIChatAttachment?)? = nil
    let onSelectAppAttachment: () -> [AppAttachmentOption]
    let onOpenAttachment: (AIChatAttachment) -> Void
    var onPaneDrop: ((String) -> Bool)? = nil

    /// Identifies this on-screen instance to the store's "is anyone looking"
    /// tracking. One per instance, so two panels cannot cancel each other.
    @State private var surfaceID = UUID()

    var body: some View {
        AIChatPane(
            threads: store.threads,
            selectedThread: store.selectedThread,
            draft: Binding(get: { store.activeDraft }, set: { store.activeDraft = $0 }),
            attachments: Binding(get: { store.activeAttachments }, set: { store.activeAttachments = $0 }),
            onSelectThread: { store.select($0) },
            onNewThread: { store.startNewThread() },
            onDeleteThread: { store.delete($0) },
            onSend: { store.send(noteContext: noteContext()) },
            respondingThreadIDs: store.respondingThreadIDs,
            onCancel: { store.cancelResponse() },
            onGradeProof: { store.submitProof($0) },
            onInsertAssistantMessage: onInsertAssistantMessage,
            onAttachDroppedTab: onAttachDroppedTab,
            onSelectAppAttachment: onSelectAppAttachment,
            onOpenAttachment: onOpenAttachment,
            onPaneDrop: onPaneDrop
        )
        .onAppear { store.surfaceDidAppear(surfaceID) }
        .onDisappear { store.surfaceDidDisappear(surfaceID) }
    }
}

@MainActor
final class SpeechInputController: ObservableObject {
    @Published var isRecording = false
    @Published var isCallMode = false
    @Published var statusText = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var baseText = ""

    func toggleDictation(draft: Binding<String>) {
        if isRecording {
            stop()
        } else {
            start(draft: draft, callMode: false)
        }
    }

    func toggleCall(draft: Binding<String>) {
        if isRecording && isCallMode {
            stop()
        } else {
            start(draft: draft, callMode: true)
        }
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        isCallMode = false
        statusText = ""
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func start(draft: Binding<String>, callMode: Bool) {
        Task {
            let authorized = await requestAuthorization()
            guard authorized else {
                statusText = L("マイクまたは音声認識の許可が必要です。")
                return
            }
            do {
                try beginRecognition(draft: draft, callMode: callMode)
            } catch {
                statusText = L("音声入力を開始できませんでした：\(error.localizedDescription)")
                stop()
            }
        }
    }

    private func requestAuthorization() async -> Bool {
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        let micAllowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }

        return speechAllowed && micAllowed
    }

    private func beginRecognition(draft: Binding<String>, callMode: Bool) throws {
        stop()
        baseText = draft.wrappedValue

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        request = newRequest

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak newRequest] buffer, _ in
            newRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isRecording = true
        isCallMode = callMode
        statusText = callMode ? L("通話モードで聞き取っています…") : L("文字起こし中…")

        task = recognizer?.recognitionTask(with: newRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let text = result?.bestTranscription.formattedString {
                    let separator = self.baseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
                    draft.wrappedValue = self.baseText + separator + text
                }
                if error != nil || result?.isFinal == true {
                    self.stop()
                }
            }
        }
    }
}

struct AppAttachmentPicker: View {
    let options: [AppAttachmentOption]
    let onSelect: (AppAttachmentOption) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredOptions: [AppAttachmentOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return options }
        return options.filter {
            $0.title.localizedCaseInsensitiveContains(query)
            || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredOptions) { option in
                Button {
                    onSelect(option)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: option.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(option.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if options.isEmpty {
                    ContentUnavailableView(
                        L("追加できる資料がありません"),
                        systemImage: "tray",
                        description: Text(L("ホーム画面で資料を作成すると、ここからAIトークに追加できます。"))
                    )
                }
            }
            .navigationTitle(L("資料を追加"))
            .searchable(text: $searchText, prompt: L("資料を検索"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("閉じる")) { dismiss() }
                }
            }
        }
    }
}

struct AIChatPane: View {
    let threads: [AIChatThread]
    let selectedThread: AIChatThread?
    @Binding var draft: String
    @Binding var attachments: [AIChatAttachment]
    let onSelectThread: (AIChatThread) -> Void
    let onNewThread: () -> Void
    let onDeleteThread: (AIChatThread) -> Void
    let onSend: () -> Void
    let respondingThreadIDs: Set<String>
    let onCancel: () -> Void
    /// Runs the two-stage marker over whatever the marking box collected.
    let onGradeProof: (ProofSubmission) -> Void
    /// Only the note editor can paste a reply onto a page; without it the
    /// "ページに貼り付け" menu item is not offered.
    let onInsertAssistantMessage: ((String) -> Void)?
    /// Lets a tab dragged from the editor's tab bar become an attachment.
    let onAttachDroppedTab: ((String) -> AIChatAttachment?)?
    let onSelectAppAttachment: () -> [AppAttachmentOption]
    let onOpenAttachment: (AIChatAttachment) -> Void
    /// Routes a drop that is not an attachment (the editor swaps panes with it).
    let onPaneDrop: ((String) -> Bool)?

    init(
        threads: [AIChatThread],
        selectedThread: AIChatThread?,
        draft: Binding<String>,
        attachments: Binding<[AIChatAttachment]>,
        onSelectThread: @escaping (AIChatThread) -> Void,
        onNewThread: @escaping () -> Void,
        onDeleteThread: @escaping (AIChatThread) -> Void,
        onSend: @escaping () -> Void,
        respondingThreadIDs: Set<String>,
        onCancel: @escaping () -> Void,
        onGradeProof: @escaping (ProofSubmission) -> Void,
        onInsertAssistantMessage: ((String) -> Void)? = nil,
        onAttachDroppedTab: ((String) -> AIChatAttachment?)? = nil,
        onSelectAppAttachment: @escaping () -> [AppAttachmentOption],
        onOpenAttachment: @escaping (AIChatAttachment) -> Void,
        onPaneDrop: ((String) -> Bool)? = nil
    ) {
        self.threads = threads
        self.selectedThread = selectedThread
        self._draft = draft
        self._attachments = attachments
        self.onSelectThread = onSelectThread
        self.onNewThread = onNewThread
        self.onDeleteThread = onDeleteThread
        self.onSend = onSend
        self.respondingThreadIDs = respondingThreadIDs
        self.onCancel = onCancel
        self.onGradeProof = onGradeProof
        self.onInsertAssistantMessage = onInsertAssistantMessage
        self.onAttachDroppedTab = onAttachDroppedTab
        self.onSelectAppAttachment = onSelectAppAttachment
        self.onOpenAttachment = onOpenAttachment
        self.onPaneDrop = onPaneDrop
    }

    /// Whether the app knows where its AI server is. The API key itself lives
    /// on that server, so there is nothing for the student to enter.
    @State private var hasKey = AI.provider.isConfigured
    /// Mirrors `AIModelSelection.current` into `@State` so picking a model
    /// from `modelPickerButton`'s menu redraws the header immediately,
    /// rather than waiting for the next time this view happens to rebuild.
    @State private var selectedModel = AIModelSelection.current
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    /// What the student chose with the sidebar button; `nil` until they do,
    /// in which case the width decides (a narrow pane starts with the history
    /// folded away so the conversation keeps room).
    @State private var historyPreference: Bool?
    @State private var measuredWidth: CGFloat = 1000
    private static let historySidebarMinimumWidth: CGFloat = 560

    private var isHistorySidebarVisible: Bool {
        historyPreference ?? Self.prefersHistorySidebar(width: measuredWidth)
    }

    /// Whether a pane this wide has room for the history beside the
    /// conversation (210pt of history plus a usable chat column).
    static func prefersHistorySidebar(width: CGFloat) -> Bool {
        width >= historySidebarMinimumWidth
    }
    @State private var pendingDeleteThread: AIChatThread?
    @State private var attachmentPickerMode: AttachmentPickerMode?
    @State private var isDropTargeted = false
    @State private var isComposerDropTargeted = false
    /// The marking box, opened from the composer's + menu.
    @State private var isMarkingBoxOpen = false
    @State private var showsAppAttachmentPicker = false
    @State private var markingQuestionText = ""
    @State private var markingAnswerText = ""
    @State private var markingQuestionSnippet: PageSnippet?
    @State private var markingAnswerSnippet: PageSnippet?
    @State private var showsCameraScanner = false
    @StateObject private var speechInput = SpeechInputController()

    private enum AttachmentPickerMode: Identifiable {
        case files
        case folder

        var id: String {
            switch self {
            case .files: return "files"
            case .folder: return "folder"
            }
        }

        var allowedContentTypes: [UTType] {
            switch self {
            case .files: return [.item]
            case .folder: return [.folder]
            }
        }
    }

    /// Shows the model AIトーク currently talks to, and lets the student
    /// switch — scoped by `subscriptionStore.currentPlan`: a model the plan
    /// doesn't unlock yet shows a lock icon and which plan would unlock it,
    /// and tapping it does nothing (the Worker would reject it with 403
    /// anyway; this just avoids a round trip to find that out).
    private var modelPickerButton: some View {
        Menu {
            ForEach(AIModelCatalog.all) { model in
                let isAvailable = AIModelCatalog.isAvailable(model.id, for: subscriptionStore.currentPlan)
                Button {
                    guard isAvailable else { return }
                    selectedModel = model.id
                    AIModelSelection.current = model.id
                } label: {
                    if isAvailable {
                        Text(model.displayName)
                    } else {
                        Label(L("\(model.displayName)（\(model.requiredPlan.title)で利用可能）"), systemImage: "lock.fill")
                    }
                }
                .disabled(!isAvailable)
            }
        } label: {
            HStack(spacing: 3) {
                Text(AIModelCatalog.info(for: selectedModel)?.displayName ?? selectedModel.rawValue)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if isHistorySidebarVisible {
                    historySidebar
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    Divider()
                }

                VStack(spacing: 0) {
                    HStack {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                historyPreference = !isHistorySidebarVisible
                            }
                        } label: {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(isHistorySidebarVisible ? L("履歴を閉じる") : L("履歴を開く"))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedThread?.title ?? L("新しいトーク"))
                                .font(.headline)
                                .lineLimit(1)
                            if hasKey {
                                modelPickerButton
                            } else {
                                Text(L("AIサーバー未設定"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: hasKey ? "sparkles" : "exclamationmark.triangle")
                            .foregroundStyle(hasKey ? Color.accentColor : Color.orange)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial)

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 14) {
                                if messages.isEmpty {
                                    VStack(spacing: 12) {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 34))
                                            .foregroundStyle(Color.accentColor)
                                        Text("何を手伝いましょうか？")
                                            .font(.title3.weight(.semibold))
                                        Text(hasKey
                                             ? L("開いているページの内容も踏まえて答えます。わからないところを聞いてみてください。")
                                             : L("AIサーバーのURLが設定されていません。ホーム画面の設定からMCPクラウド連携を確認してください。"))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 30)
                                    }
                                    .padding(.top, 60)
                                    .frame(maxWidth: .infinity)
                                }

                                ForEach(messages) { message in
                                    AIChatBubble(
                                        message: message,
                                        onInsertOnPage: onInsertAssistantMessage.map { insert in
                                            { insert(message.text) }
                                        }
                                    )
                                        .id(message.persistentModelID)
                                }
                            }
                            .padding(18)
                        }
                        .onChange(of: messages.count) { _, _ in
                            if let last = messages.last {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(last.persistentModelID, anchor: .bottom)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        if !attachments.isEmpty {
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    ForEach(attachments) { attachment in
                                        attachmentChip(attachment)
                                    }
                                }
                                .padding(.horizontal, 2)
                            }
                            .scrollIndicators(.hidden)
                        }

                        if isMarkingBoxOpen { markingBox }

                        HStack(alignment: .bottom, spacing: 10) {
                            Menu {
                                Button {
                                    showsAppAttachmentPicker = true
                                } label: {
                                    Label(L("アプリ内の資料を追加"), systemImage: "square.grid.2x2")
                                }

                                Divider()

                                Button {
                                    attachmentPickerMode = .files
                                } label: {
                                    Label(L("ファイルを追加"), systemImage: "doc.badge.plus")
                                }

                                Button {
                                    attachmentPickerMode = .folder
                                } label: {
                                    Label(L("フォルダーを追加"), systemImage: "folder.badge.plus")
                                }

                                Button {
                                    showsCameraScanner = true
                                } label: {
                                    Label(L("カメラで撮影"), systemImage: "camera")
                                }
                                .disabled(!VNDocumentCameraViewController.isSupported)

                                Button {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                        isMarkingBoxOpen = true
                                    }
                                } label: {
                                    Label(L("AI採点"), systemImage: "checkmark.seal")
                                }
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .frame(width: 34, height: 34)
                                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                            }
                            .accessibilityLabel(L("ファイルやフォルダーを追加"))

                            TextField("メッセージを入力", text: $draft, axis: .vertical)
                                .lineLimit(1...5)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                                .submitLabel(.send)
                                .onSubmit(onSend)
                                .accessibilityIdentifier("ai-chat-draft")

                            Button {
                                speechInput.toggleDictation(draft: $draft)
                            } label: {
                                Image(systemName: speechInput.isRecording && !speechInput.isCallMode ? "waveform.circle.fill" : "waveform")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(speechInput.isRecording && !speechInput.isCallMode ? Color.accentColor : .primary)
                                    .frame(width: 34, height: 34)
                                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L("文字起こし"))

                            Button {
                                speechInput.toggleCall(draft: $draft)
                            } label: {
                                Image(systemName: speechInput.isRecording && speechInput.isCallMode ? "phone.circle.fill" : "phone")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(speechInput.isRecording && speechInput.isCallMode ? Color.green : .primary)
                                    .frame(width: 34, height: 34)
                                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L("通話"))

                            // Turns into a stop button while a reply is streaming, so
                            // a long answer can be cut short.
                            Button(action: isResponding ? onCancel : onSend) {
                                Image(systemName: isResponding ? "stop.fill" : "arrow.up")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .background(sendButtonColor, in: Circle())
                            }
                            .disabled(!isResponding && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel(isResponding ? L("生成を止める") : L("送信"))
                            .accessibilityIdentifier(isResponding ? "ai-chat-stop" : "ai-chat-send")
                        }

                        if !speechInput.statusText.isEmpty {
                            Text(speechInput.statusText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 44)
                        }
                    }
                    .padding(12)
                    .background(.regularMaterial)
                    .scaleEffect(isComposerDropTargeted ? 1.04 : 1.0)
                    .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isComposerDropTargeted)
                    .dropDestination(for: String.self) { items, _ in
                        guard let value = items.first else { return false }
                        if let attachment = onAttachDroppedTab?(value) {
                            attachments.append(attachment)
                            return true
                        }
                        if isPaneSwitchDrop(value) {
                            return false
                        }
                        return onPaneDrop?(value) ?? false
                    } isTargeted: { targeted in
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
                            isComposerDropTargeted = targeted
                        }
                    }
                    .overlay {
                        if isComposerDropTargeted {
                            ZStack {
                                RoundedRectangle(cornerRadius: 22)
                                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [7, 5]))
                                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
                                Image(systemName: "plus")
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                }
            }

            if let pendingDeleteThread {
                deleteConfirmationCard(for: pendingDeleteThread)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: AIChatPaneWidthKey.self, value: proxy.size.width.rounded())
            }
        )
        .onPreferenceChange(AIChatPaneWidthKey.self) { width in
            if width > 0, width != measuredWidth { measuredWidth = width }
        }
        // The whole pane accepts crops, not just the composer — aiming a
        // drag at a text field on a split screen is fiddly, and there is
        // nothing else here a page snippet could mean.
        .dropDestination(for: PageSnippet.self) { snippets, _ in
            for snippet in snippets { accept(snippet) }
            return !snippets.isEmpty
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) { isDropTargeted = targeted }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let value = items.first else { return false }
            return onPaneDrop?(value) ?? false
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .fileImporter(
            isPresented: attachmentPickerBinding,
            allowedContentTypes: attachmentPickerMode?.allowedContentTypes ?? [.item],
            allowsMultipleSelection: attachmentPickerMode == .files
        ) { result in
            guard let mode = attachmentPickerMode else { return }
            if case .success(let urls) = result {
                let kind: AIChatAttachment.Kind = mode == .folder ? .folder : .file
                attachments.append(contentsOf: urls.map {
                    AIChatAttachment(name: $0.lastPathComponent, path: $0.path, kind: kind)
                })
            }
            attachmentPickerMode = nil
        }
        .sheet(isPresented: $showsCameraScanner) {
            DocumentScannerView { images in
                attachments.append(contentsOf: images.enumerated().compactMap { index, image in
                    guard let data = image.pngData() else { return nil }
                    return AIChatAttachment(
                        name: L("撮影画像 \(index + 1)"),
                        path: "",
                        kind: .camera,
                        imageData: data
                    )
                })
            }
        }
        .sheet(isPresented: $showsAppAttachmentPicker) {
            AppAttachmentPicker(
                options: onSelectAppAttachment(),
                onSelect: { option in
                    attachments.append(option.attachment)
                    showsAppAttachmentPicker = false
                }
            )
        }
    }

    private func isPaneSwitchDrop(_ value: String) -> Bool {
        value.hasPrefix("notebook:")
            || value.hasPrefix("deck:")
            || value.hasPrefix("web:")
            || value.hasPrefix("ai:")
            || value.hasPrefix("friend:")
            || value.hasPrefix("group:")
    }

    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onNewThread) {
                Label("新しいトーク", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("ai-chat-new-thread")

            Text("履歴")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            List {
                ForEach(threads) { thread in
                    Button {
                        onSelectThread(thread)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "message")
                                .foregroundStyle(.secondary)
                            Text(thread.title)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if isResponding(thread) {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(
                            isSelected(thread)
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ai-chat-thread-\(thread.title)")
                    .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeleteThread = thread
                        } label: {
                            Label(L("削除"), systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .padding(12)
        .frame(width: 210)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var messages: [AIChatMessage] {
        selectedThread?.sortedMessages ?? []
    }

    private var isResponding: Bool {
        guard let selectedThread else { return false }
        return isResponding(selectedThread)
    }

    private func isResponding(_ thread: AIChatThread) -> Bool {
        respondingThreadIDs.contains(String(describing: thread.persistentModelID))
    }

    private func isSelected(_ thread: AIChatThread) -> Bool {
        selectedThread?.persistentModelID == thread.persistentModelID
    }

    private func deleteConfirmationCard(for thread: AIChatThread) -> some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture {
                    pendingDeleteThread = nil
                }

            VStack(spacing: 14) {
                Image(systemName: "trash")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.red)

                VStack(spacing: 6) {
                    Text(L("このトークを削除しますか？"))
                        .font(.headline)
                    Text(L("削除すると、このトーク履歴は元に戻せません。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button {
                        pendingDeleteThread = nil
                    } label: {
                        Text(L("いいえ"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        onDeleteThread(thread)
                        pendingDeleteThread = nil
                    } label: {
                        Text(L("はい"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityIdentifier("ai-chat-delete-confirm")
                }
            }
            .padding(18)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
            .padding(24)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .zIndex(20)
    }

    private var attachmentPickerBinding: Binding<Bool> {
        Binding(
            get: { attachmentPickerMode != nil },
            set: { isPresented in
                if !isPresented {
                    attachmentPickerMode = nil
                }
            }
        )
    }

    @ViewBuilder
    private func attachmentChip(_ attachment: AIChatAttachment) -> some View {
        if attachment.kind == .snippet, let snippet = attachment.snippet {
            snippetChip(attachment, snippet: snippet)
        } else {
            Button {
                onOpenAttachment(attachment)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: attachment.kind.icon)
                        .foregroundStyle(.secondary)
                    Text(attachment.name)
                        .lineLimit(1)
                    Button {
                        attachments.removeAll { $0.id == attachment.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("添付を削除"))
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    /// A dropped crop, with the role picker that decides whether this is a
    /// marking request or just an image to talk about.
    private func snippetChip(_ attachment: AIChatAttachment, snippet: PageSnippet) -> some View {
        VStack(spacing: 4) {
            Group {
                if let image = snippet.image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 104, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            Menu {
                Picker(L("役割"), selection: roleBinding(for: attachment)) {
                    ForEach(AIChatAttachment.ProofRole.allCases) { role in
                        Text(role.label).tag(role)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(attachment.proofRole.label)
                    Image(systemName: "chevron.down")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(attachment.proofRole.tint)
            }
        }
        .padding(6)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(attachment.proofRole == .none ? .clear : attachment.proofRole.tint, lineWidth: 1.5)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(Color(uiColor: .systemBackground)))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
            .accessibilityLabel(L("添付を削除"))
        }
    }

    private func roleBinding(for attachment: AIChatAttachment) -> Binding<AIChatAttachment.ProofRole> {
        Binding(
            get: { attachments.first { $0.id == attachment.id }?.proofRole ?? .none },
            set: { newRole in
                guard let index = attachments.firstIndex(where: { $0.id == attachment.id }) else { return }
                // Only one crop can be the question and only one the answer,
                // so claiming a role takes it off whoever held it.
                if newRole != .none {
                    for other in attachments.indices where attachments[other].proofRole == newRole {
                        attachments[other].proofRole = .none
                    }
                }
                attachments[index].proofRole = newRole
                // Tagging a crop is the same intent as opening the box from
                // the menu, so the box comes out to receive it.
                if newRole != .none { adoptTaggedSnippets() }
            }
        )
    }

    /// Moves crops the student has tagged into the marking box's slots.
    private func adoptTaggedSnippets() {
        if let question = attachments.first(where: { $0.proofRole == .question })?.snippet {
            markingQuestionSnippet = question
        }
        if let answer = attachments.first(where: { $0.proofRole == .answer })?.snippet {
            markingAnswerSnippet = answer
        }
        attachments.removeAll { $0.kind == .snippet && $0.proofRole != .none }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { isMarkingBoxOpen = true }
    }

    /// Files a dropped crop.
    ///
    /// While the marking box is open a drop fills its empty slot, which is
    /// what makes "問題をドラッグ、解答をドラッグ、採点" work without any
    /// tagging. Otherwise it lands in the composer as a taggable chip.
    private func accept(_ snippet: PageSnippet) {
        if isMarkingBoxOpen {
            if markingQuestionSnippet == nil {
                markingQuestionSnippet = snippet
            } else {
                markingAnswerSnippet = snippet
            }
            return
        }
        let taken = Set(attachments.map(\.proofRole))
        let role: AIChatAttachment.ProofRole =
            !taken.contains(.question) ? .question : (!taken.contains(.answer) ? .answer : .none)
        attachments.append(AIChatAttachment(
            name: snippet.sourceLabel,
            path: "",
            kind: .snippet,
            snippet: snippet,
            proofRole: role
        ))
    }

    // MARK: Marking box

    private var markingSubmission: ProofSubmission {
        ProofSubmission(
            questionText: markingQuestionText.trimmingCharacters(in: .whitespacesAndNewlines),
            questionImage: markingQuestionSnippet?.image,
            answerText: markingAnswerText.trimmingCharacters(in: .whitespacesAndNewlines),
            answerImage: markingAnswerSnippet?.image
        )
    }

    /// Where a proof is handed over for marking.
    ///
    /// Each half takes typing or a dropped crop, because a question is
    /// usually printed in a PDF while the working is often quicker to type
    /// than to photograph — and either can be the other way round.
    private var markingBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.accentColor)
                Text("AI採点")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { closeMarkingBox() }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("採点をやめる"))
            }

            markingSlot(
                title: L("問題"),
                placeholder: L("問題文を入力、またはページを切り抜いてドラッグ"),
                tint: .indigo,
                text: $markingQuestionText,
                snippet: $markingQuestionSnippet
            )
            markingSlot(
                title: L("解答"),
                placeholder: L("自分の証明を入力、またはページを切り抜いてドラッグ"),
                tint: .teal,
                text: $markingAnswerText,
                snippet: $markingAnswerSnippet
            )

            Button {
                let submission = markingSubmission
                onGradeProof(submission)
                withAnimation(.easeOut(duration: 0.2)) { closeMarkingBox() }
            } label: {
                Label(L("採点する"), systemImage: "checkmark.seal")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(canMark ? Color.accentColor : Color.secondary.opacity(0.3),
                                in: RoundedRectangle(cornerRadius: 11))
                    .foregroundStyle(canMark ? .white : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canMark)
        }
        .padding(12)
        .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var canMark: Bool {
        !isResponding && markingSubmission.hasQuestion && markingSubmission.hasAnswer
    }

    private func closeMarkingBox() {
        isMarkingBoxOpen = false
        markingQuestionText = ""
        markingAnswerText = ""
        markingQuestionSnippet = nil
        markingAnswerSnippet = nil
    }

    private func markingSlot(
        title: String,
        placeholder: String,
        tint: Color,
        text: Binding<String>,
        snippet: Binding<PageSnippet?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)

            if let image = snippet.wrappedValue?.image {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.35), lineWidth: 1))

                    Button {
                        snippet.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white, Color.black.opacity(0.55))
                            .background(Circle().fill(Color.black.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("画像を外す"))
                    .offset(x: 7, y: -7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }

            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(1...6)
                .font(.subheadline)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
        .dropDestination(for: PageSnippet.self) { items, _ in
            guard let dropped = items.first else { return false }
            snippet.wrappedValue = dropped
            return true
        }
    }

    private var sendButtonColor: Color {
        if isResponding { return .red }
        return draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .gray : .accentColor
    }
}

struct AIChatBubble: View {
    let message: AIChatMessage
    /// `nil` where there is no page to paste onto (the home AI screen).
    let onInsertOnPage: (() -> Void)?

    /// Follows Dynamic Type like the `.body` text it replaces.
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 17

    var body: some View {
        if message.role == .assistant {
            RichMessageView(source: message.text, fontSize: bodySize)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu {
                    // Copies readable text, never the raw LaTeX.
                    Button {
                        UIPasteboard.general.string = MathTextFormatter.plainText(from: message.text)
                    } label: {
                        Label(L("コピー"), systemImage: "doc.on.doc")
                    }
                    if let onInsertOnPage {
                        Button(action: onInsertOnPage) {
                            Label(L("ページに貼り付け"), systemImage: "text.badge.plus")
                        }
                    }
                }
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                Spacer(minLength: 40)

                Text(message.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
                    .frame(maxWidth: 520, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

