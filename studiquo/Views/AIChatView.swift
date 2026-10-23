import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers
import VisionKit

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
/// Recognises a dragged tab's id that a text field swallowed as plain text.
/// Where the AIチャット message list rests when it is shown. A conversation
/// opens on its newest message; only the empty-state greeting starts at the top.
enum AIChatScrollPolicy {
    static func anchor(messageCount: Int) -> UnitPoint {
        messageCount == 0 ? .top : .bottom
    }
}

enum DroppedTabText {
    static let prefixes = ["notebook:", "deck:", "web:", "ai:", "friend:", "group:", "document:"]

    /// The tab id inserted by the change from `old` to `new`, or nil when the
    /// change is ordinary typing, a deletion, or text that is not a tab id.
    static func tabID(old: String, new: String) -> String? {
        guard new.count > old.count else { return nil }
        let oldChars = Array(old), newChars = Array(new)
        var prefix = 0
        while prefix < oldChars.count, oldChars[prefix] == newChars[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldChars.count - prefix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] { suffix += 1 }
        let inserted = String(newChars[prefix..<(newChars.count - suffix)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prefixes.contains(where: inserted.hasPrefix) ? inserted : nil
    }
}

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
    /// The age band picked on the consent card (nothing preselected).
    @State private var consentAge: AIAgeBand?
    @State private var consentUnder13 = false

    var body: some View {
        AIChatPane(
            threads: store.threads,
            selectedThread: store.selectedThread,
            draft: Binding(get: { store.activeDraft }, set: { store.activeDraft = $0 }),
            attachments: Binding(get: { store.activeAttachments }, set: { store.activeAttachments = $0 }),
            onSelectThread: { store.select($0) },
            onNewThread: { store.startNewThread() },
            onDeleteThread: { store.delete($0) },
            onRenameThread: { store.rename($0, to: $1) },
            onSend: { store.send(noteContext: noteContext()) },
            onResend: { store.resend($0, noteContext: noteContext()) },
            respondingThreadIDs: store.respondingThreadIDs,
            onCancel: { store.cancelResponse() },
            onGradeProof: { store.submitProof($0) },
            onInsertAssistantMessage: onInsertAssistantMessage,
            onAttachDroppedTab: onAttachDroppedTab,
            onSelectAppAttachment: onSelectAppAttachment,
            onOpenAttachment: onOpenAttachment,
            onPaneDrop: onPaneDrop
        )
        .overlay {
            if store.pendingConsentSend != nil {
                consentCard
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.pendingConsentSend != nil)
        .onAppear { store.surfaceDidAppear(surfaceID) }
        .onDisappear { store.surfaceDidDisappear(surfaceID) }
    }

    private var consentCard: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                VStack(spacing: 6) {
                    Text(L("AIへの送信を許可しますか？"))
                        .font(.headline)
                    Text(L("質問・会話履歴と、送信対象として選んだ資料・画像がOpenAI(ChatGPTのモデル)へ送信されます。許可はいつでも設定 → プライバシーから取り消せます。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("年齢の確認(13〜17歳は保護者の同意が必要です)"))
                        .font(.caption.weight(.semibold))
                    consentAgeOption(L("18歳以上です"), selected: consentAge == .adult && !consentUnder13) {
                        consentAge = .adult; consentUnder13 = false
                    }
                    consentAgeOption(L("13〜17歳で、保護者の同意を得ています"), selected: consentAge == .teen && !consentUnder13) {
                        consentAge = .teen; consentUnder13 = false
                    }
                    consentAgeOption(L("13歳未満です"), selected: consentUnder13) {
                        consentAge = nil; consentUnder13 = true
                    }
                    if consentUnder13 {
                        Text(L("13歳未満の方はAI機能を利用できません。"))
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Button { store.declinePendingSend() } label: {
                        Text(L("許可しない")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.themeSecondary)
                    .accessibilityIdentifier("ai-chat-consent-decline")
                    Button {
                        if let consentAge { store.allowPendingSend(ageBand: consentAge) }
                    } label: {
                        Text(L("許可して送信")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.themePrimary)
                    .disabled(consentAge == nil)
                    .accessibilityIdentifier("ai-chat-consent-allow")
                }
            }
            .padding(18)
            .frame(maxWidth: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.Palette.line, lineWidth: Theme.Stroke.hairline))
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
            .padding(24)
        }
        .transition(.opacity)
        .zIndex(30)
    }
}

extension AIChatPanel {
    fileprivate func consentAgeOption(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                Text(title).font(.caption).foregroundStyle(.primary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
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
                            .foregroundStyle(Theme.Palette.accent)
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
                .themeScreenBackground()
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
    let onRenameThread: (AIChatThread, String) -> Void
    let onSend: () -> Void
    let onResend: (String) -> Bool
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
        onRenameThread: @escaping (AIChatThread, String) -> Void,
        onSend: @escaping () -> Void,
        onResend: @escaping (String) -> Bool,
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
        self.onRenameThread = onRenameThread
        self.onSend = onSend
        self.onResend = onResend
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
    @State private var renamingThread: AIChatThread?
    @State private var renameDraft = ""
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
    @State private var usage: AIUsage?
    /// Only one historical prompt can be edited at a time. Keeping this in
    /// the pane (rather than each bubble) avoids two inline editors competing
    /// for attention on a touch-first screen.
    @State private var editingMessageID: PersistentIdentifier?
    @State private var editedPrompt = ""

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
                            if !hasKey {
                                Text(L("AIサーバー未設定"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let usage {
                            Text("残り\(usage.remaining)回")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("ai-chat-usage")
                                .accessibilityLabel("AI利用残り\(usage.remaining)回")
                        }
                        Image(systemName: hasKey ? "sparkles" : "exclamationmark.triangle")
                            .foregroundStyle(hasKey ? Theme.Palette.accent : Theme.Palette.warning)
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
                                            .foregroundStyle(Theme.Palette.accent)
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
                                        },
                                        isEditing: editingMessageID == message.persistentModelID,
                                        editedText: $editedPrompt,
                                        canEdit: !isResponding,
                                        onBeginEditing: {
                                            editingMessageID = message.persistentModelID
                                            editedPrompt = message.text
                                        },
                                        onCancelEditing: cancelMessageEditing,
                                        onResend: { text in
                                            let didSend = onResend(text)
                                            if didSend { cancelMessageEditing() }
                                            return didSend
                                        }
                                    )
                                        .id(message.persistentModelID)
                                }
                            }
                            .padding(18)
                        }
                        .defaultScrollAnchor(AIChatScrollPolicy.anchor(messageCount: messages.count))
                        .onAppear {
                            if let last = messages.last {
                                proxy.scrollTo(last.persistentModelID, anchor: .bottom)
                            }
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
                                    .background(Theme.Palette.surface, in: Circle())
                            }
                            .accessibilityLabel(L("ファイルやフォルダーを追加"))

                            TextField("メッセージを入力", text: $draft, axis: .vertical)
                                .lineLimit(1...5)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
                                .submitLabel(.send)
                                .onSubmit(onSend)
                                .accessibilityIdentifier("ai-chat-draft")


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
                                RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                                    .strokeBorder(Theme.Palette.accent, style: StrokeStyle(lineWidth: 2.5, dash: [7, 5]))
                                    .background(Theme.Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
                                Image(systemName: "plus")
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
            // A dragged tab dropped anywhere but the composer (which
            // attaches it instead) replaces this pane with that material.
            // It sits on its own node, apart from the PageSnippet drop on
            // the outer ZStack, so the two drop types cannot shadow each other.
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let value = items.first else { return false }
                return onPaneDrop?(value) ?? false
            }

            if let pendingDeleteThread {
                deleteConfirmationCard(for: pendingDeleteThread)
            }
        }
        .alert(L("名前を変更"), isPresented: Binding(
            get: { renamingThread != nil },
            set: { if !$0 { renamingThread = nil } }
        )) {
            TextField(L("トークの名前"), text: $renameDraft)
                .onChange(of: renameDraft) { _, value in
                    if value.count > AIChatStore.maxTitleLength {
                        renameDraft = String(value.prefix(AIChatStore.maxTitleLength))
                    }
                }
            Button(L("キャンセル"), role: .cancel) {}
            Button(L("保存")) {
                if let renamingThread { onRenameThread(renamingThread, renameDraft) }
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .background(Theme.Palette.canvas)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: AIChatPaneWidthKey.self, value: proxy.size.width.rounded())
            }
        )
        .onChange(of: draft) { oldValue, newValue in
            absorbDroppedTabText(old: oldValue, new: newValue)
        }
        .task { await refreshUsage() }
        .onChange(of: respondingThreadIDs) { _, responding in
            if responding.isEmpty { Task { await refreshUsage() } }
        }
        .onPreferenceChange(AIChatPaneWidthKey.self) { width in
            if width > 0, width != measuredWidth { measuredWidth = width }
        }
        .onChange(of: selectedThread?.persistentModelID) { _, _ in
            cancelMessageEditing()
        }
        // The whole pane accepts crops, not just the composer — aiming a
        // drag at a text field on a split screen is fiddly, and there is
        // nothing else here a page snippet could mean. It also accepts a tab,
        // which switches this pane to that material (the composer, inside,
        // keeps attaching tabs instead).
        //
        // ONE destination for both kinds: with one destination per type on the
        // same view, only one is consulted and the tab drop never arrived.
        // See `PaneDropPayload`.
        .dropDestination(for: PaneDropPayload.self) { drops, _ in
            var handled = false
            for drop in drops {
                switch drop {
                case .snippet(let snippet):
                    accept(snippet)
                    handled = true
                case .tab(let value):
                    if onPaneDrop?(value) ?? false { handled = true }
                }
            }
            return handled
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) { isDropTargeted = targeted }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                    .strokeBorder(Theme.Palette.accent, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
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

    /// The text field takes a dragged tab's id as plain text before the
    /// composer's drop handler runs. When what was just inserted is such an
    /// id, take it back out of the draft and attach the material instead.
    private func absorbDroppedTabText(old: String, new: String) {
        guard let onAttachDroppedTab,
              let tabID = DroppedTabText.tabID(old: old, new: new),
              let attachment = onAttachDroppedTab(tabID) else { return }
        draft = old
        attachments.append(attachment)
        isComposerDropTargeted = false
        isDropTargeted = false
    }

    @MainActor
    private func refreshUsage() async {
        usage = await AI.provider.usage()
    }

    private func cancelMessageEditing() {
        editingMessageID = nil
        editedPrompt = ""
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
            .buttonStyle(.themeSecondary)
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
                            ? Theme.Palette.accent.opacity(0.14)
                            : Color.clear,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ai-chat-thread-\(thread.title)")
                    .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        Button {
                            renameDraft = thread.title
                            renamingThread = thread
                        } label: {
                            Label(L("名前を変更"), systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            pendingDeleteThread = thread
                        } label: {
                            Label(L("削除"), systemImage: "trash")
                        }
                    }
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
        .background(Theme.Palette.canvas)
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
                    .foregroundStyle(Theme.Palette.danger)

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
                    .buttonStyle(.themeSecondary)

                    Button(role: .destructive) {
                        onDeleteThread(thread)
                        pendingDeleteThread = nil
                    } label: {
                        Text(L("はい"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.themeDanger)
                    .accessibilityIdentifier("ai-chat-delete-confirm")
                }
            }
            .padding(18)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                    .strokeBorder(Theme.Palette.line, lineWidth: Theme.Stroke.hairline)
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
                .background(Theme.Palette.surface, in: Capsule())
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
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))

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
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .stroke(attachment.proofRole == .none ? .clear : attachment.proofRole.tint, lineWidth: 1.5)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(Theme.Palette.surface))
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
                    .foregroundStyle(Theme.Palette.accent)
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
                    .background(canMark ? Theme.Palette.accent : Color.secondary.opacity(0.3),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                    .foregroundStyle(canMark ? .white : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canMark)
        }
        .padding(12)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .stroke(Theme.Palette.accent.opacity(0.35), lineWidth: 1)
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
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).stroke(tint.opacity(0.35), lineWidth: 1))

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
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
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
    let isEditing: Bool
    @Binding var editedText: String
    let canEdit: Bool
    let onBeginEditing: () -> Void
    let onCancelEditing: () -> Void
    let onResend: (String) -> Bool

    /// Follows Dynamic Type like the `.body` text it replaces.
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 17
    @State private var didCopy = false

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
            HStack(alignment: .top, spacing: 8) {
                Spacer(minLength: 40)

                VStack(alignment: .trailing, spacing: 2) {
                    if isEditing {
                        editPanel
                    } else {
                        Text(message.text)
                            .font(.body)
                            .foregroundStyle(Theme.Palette.onAccent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Theme.Palette.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
                            .accessibilityIdentifier("ai-chat-user-message")

                        HStack(spacing: 0) {
                            Button(action: copyMessage) {
                                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(didCopy ? Color.green : .secondary)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(didCopy ? L("コピーしました") : L("コピー"))
                            .accessibilityIdentifier("ai-chat-copy-message")

                            Button(action: onBeginEditing) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!canEdit)
                            .accessibilityLabel(L("書き直す"))
                            .accessibilityIdentifier("ai-chat-edit-message")
                        }
                        .frame(height: 36)
                    }
                }
                .frame(maxWidth: 520, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var editPanel: some View {
        VStack(alignment: .trailing, spacing: 10) {
            TextField(L("メッセージを書き直す"), text: $editedText, axis: .vertical)
                .lineLimit(1...10)
                .font(.body)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                }
                .accessibilityIdentifier("ai-chat-edit-field")

            HStack(spacing: 8) {
                Button(L("キャンセル"), action: onCancelEditing)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("ai-chat-edit-cancel")

                Button(L("送信")) {
                    _ = onResend(editedText)
                }
                .buttonStyle(.borderedProminent)
                .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canEdit)
                .accessibilityIdentifier("ai-chat-edit-send")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func copyMessage() {
        UIPasteboard.general.string = message.text
        didCopy = true
        UIAccessibility.post(notification: .announcement, argument: L("コピーしました"))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}
