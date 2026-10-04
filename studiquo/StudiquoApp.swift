import CloudKit
import CoreData
import OSLog
import GoogleSignIn
import SwiftUI
import SwiftData
import UIKit
import UserNotifications

/// The language chosen in Settings, independent of the device's own
/// language. Read directly from `UserDefaults` (the `@AppStorage` key is
/// `"appLanguage"`) so it's reachable from plain Swift code — model
/// properties, notification content — that has no SwiftUI environment to
/// pull `\.locale` from.
enum AppLocale {
    static var current: Locale {
        switch UserDefaults.standard.string(forKey: "appLanguage") {
        case "japanese": Locale(identifier: "ja")
        case "english": Locale(identifier: "en")
        default: Locale.autoupdatingCurrent
        }
    }
}

/// Looks up a string in `Localizable.xcstrings` for `AppLocale.current`,
/// rather than the device's language. `Text("...")` and `Label("...")`
/// resolve against `\.locale` in the environment instead (set at the scene
/// root in `StudiquoApp`) — this covers everywhere else a string is put
/// together outside a `View`: computed properties, notification content,
/// status messages assigned to `@State`.
///
/// Both paths key off the same `appLanguage` value, so switching languages
/// in Settings updates every piece of text at once, without an app restart.
func L(_ value: String.LocalizationValue) -> String {
    // `String(localized:locale:)` accepts a `Locale`, but in practice it did
    // not reliably switch which translation came back — it kept returning
    // the Japanese source text even once `AppLocale.current` reported "en".
    // Loading the specific `<code>.lproj` bundle directly and passing that
    // instead sidesteps whatever locale-negotiation step the `locale:`
    // parameter goes through — the same outcome `.environment(\.locale:)`
    // reliably gets for plain `Text(...)`.
    let code = AppLocale.current.language.languageCode?.identifier ?? "en"
    guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
          let languageBundle = Bundle(path: path) else {
        return String(localized: value)
    }
    return String(localized: value, bundle: languageBundle)
}

func L(_ value: String) -> String { value }

/// Saved in the same SwiftData transaction as an incoming MCP item, so a
/// network retry after an app restart cannot create the item twice.
@Model
final class MCPImportReceipt {
    var id: String = ""
    var title: String = ""
    var kind: String = ""
    var source: String = ""
    var importedAt: Date = Date.now

    init(id: String, title: String, kind: String, source: String) {
        self.id = id
        self.title = title
        self.kind = kind
        self.source = source
        self.importedAt = .now
    }
}

let studiquoSchema = Schema([
    Notebook.self, NotePage.self, PageElement.self,
    FlashcardDeck.self, Flashcard.self, CalendarEvent.self, StudyActivity.self,
    AIChatThread.self, AIChatMessage.self,
    TextDocument.self, SlideDeck.self, Slide.self,
    SlideMaster.self, SlideLayoutTemplate.self, SlidePlaceholder.self, SlideElement.self,
    DocumentBlock.self, DocumentTableRow.self, DocumentTableCell.self,
    DocumentHeaderFooter.self, DocumentComment.self, DocumentChangeRecord.self, DocumentFootnote.self,
    AIReviewItem.self,
    Folder.self,
    MCPImportReceipt.self,
])

private let startupLogger = Logger(subsystem: "com.yabuko.studiquo", category: "Startup")

@MainActor
final class StudiquoAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        AppNotificationPreferences.registerCategories()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushNotificationRegistration.didRegister(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        startupLogger.error("APNs registration failed: \(String(describing: error), privacy: .public)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Banner or quiet-in-the-list or nothing, per the kind's settings.
        // A banner shows while Studiquo is foregrounded too; the destination
        // view remains the source of truth and refreshes from the server when
        // the banner is tapped.
        AppNotificationPreferences.foregroundPresentation(
            forCategory: notification.request.content.categoryIdentifier
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        if response.actionIdentifier == FlashcardReviewNotifications.snoozeActionIdentifier {
            await FlashcardReviewNotifications.snooze(content)
            return
        }
        await MainActor.run {
            NotificationCenter.default.post(
                name: .studiquoNotificationRoute,
                object: nil,
                userInfo: content.userInfo
            )
        }
    }
}

/// Only fall back after the cloud attempt has actually returned an error.
/// A deadline cannot cancel ModelContainer.init; opening another container
/// on the same store while migration is still running can contend for its lock.
private func makeStudiquoModelContainer() throws -> ModelContainer {
    startupLogger.info("Opening persistent store with CloudKit")
    do {
        let configuration = ModelConfiguration(schema: studiquoSchema, cloudKitDatabase: .automatic)
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        startupLogger.info("Persistent store ready (CloudKit)")
        return container
    } catch {
        startupLogger.error("CloudKit store open failed: \(String(describing: error), privacy: .public)")
        do {
            let configuration = ModelConfiguration(schema: studiquoSchema, cloudKitDatabase: .none)
            let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
            startupLogger.info("Persistent store ready (local)")
            return container
        } catch {
            startupLogger.error("Local store open failed: \(String(describing: error), privacy: .public)")
            // Never silently substitute an empty, unsaved in-memory library.
            throw error
        }
    }
}

@main
struct StudiquoApp: App {
    @UIApplicationDelegateAdaptor(StudiquoAppDelegate.self) private var appDelegate
    @StateObject private var startup = StartupStoreLoader(
        openStore: { try makeStudiquoModelContainer() },
        onFailure: { ErrorReportService.recordFailure(area: "起動時のデータ読み込み", error: $0) }
    )
    @AppStorage("appLanguage") private var appLanguage = "system"
    @StateObject private var cloudSyncStatus = CloudKitSyncStatus()
    @StateObject private var subscriptionStore = SubscriptionStore()

    /// Every other `SubscriptionStore` call (purchase, restore, the model
    /// picker's plan check, the storage-limit check) assumes RevenueCat is
    /// already configured — this has to run before `subscriptionStore`'s own
    /// `init()` above makes its first `Purchases.shared` call, so it can't
    /// simply live inside `body`'s `.task` alongside `startup.start()`.
    init() {
        SubscriptionStore.configureSDK()
        CrashDiagnosticsSubscriber.shared.start()
        CloudKitErrorReporting.start()
    }

    private var resolvedLocale: Locale {
        switch appLanguage {
        case "japanese": Locale(identifier: "ja")
        case "english": Locale(identifier: "en")
        default: Locale.autoupdatingCurrent
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--startup-ui-test") {
                    StartupUITestRoot()
                } else if ProcessInfo.processInfo.arguments.contains("--library-drop-ui-test") {
                    LibraryDropUITestRoot()
                } else if ProcessInfo.processInfo.arguments.contains("--friend-chat-ui-test") {
                    FriendChatUITestRoot()
                } else if ProcessInfo.processInfo.arguments.contains("--note-snippet-friend-ui-test") ||
                            ProcessInfo.processInfo.arguments.contains("--note-snippet-group-ui-test") ||
                            ProcessInfo.processInfo.arguments.contains("--note-snippet-friend-drag-ui-test") ||
                            ProcessInfo.processInfo.arguments.contains("--note-snippet-group-drag-ui-test") {
                    NoteSnippetFriendUITestRoot()
                } else if ProcessInfo.processInfo.arguments.contains("--math-spike") {
                    MathSpikeView()
                } else if ProcessInfo.processInfo.arguments.contains("--note-ai-chat-ui-test") {
                    NoteAIChatUITestRoot()
                } else if ProcessInfo.processInfo.arguments.contains("--tab-picker-create-ui-test") {
                    TabPickerCreateUITestRoot()
                } else {
                    normalRoot
                }
                #else
                normalRoot
                #endif
            }
            .preferredColorScheme(.light)
            .task {
                #if DEBUG
                guard !ProcessInfo.processInfo.arguments.contains("--library-drop-ui-test"),
                      !ProcessInfo.processInfo.arguments.contains("--startup-ui-test"),
                      !ProcessInfo.processInfo.arguments.contains("--friend-chat-ui-test"),
                      !ProcessInfo.processInfo.arguments.contains("--note-snippet-friend-ui-test"),
                      !ProcessInfo.processInfo.arguments.contains("--note-snippet-group-ui-test"),
                      !ProcessInfo.processInfo.arguments.contains("--note-snippet-friend-drag-ui-test"),
                      !ProcessInfo.processInfo.arguments.contains("--note-snippet-group-drag-ui-test"),
                      !ProcessInfo.processInfo.arguments.contains("--math-spike"),
                      !ProcessInfo.processInfo.arguments.contains("--note-ai-chat-ui-test"),
                      !ProcessInfo.processInfo.arguments.contains("--tab-picker-create-ui-test") else { return }
                #endif
                startup.start()
            }
        }
    }

    @ViewBuilder private var normalRoot: some View {
        if case .ready(let modelContainer) = startup.state {
            AccountGateView()
                .modelContainer(modelContainer)
                .environmentObject(subscriptionStore)
                .tint(Color(red: 0.16, green: 0.33, blue: 0.63))
                .environment(\.locale, resolvedLocale)
                .overlay(alignment: .top) {
                    if cloudSyncStatus.isShowingFirstSyncBanner {
                        FirstCloudSyncBanner()
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut, value: cloudSyncStatus.isShowingFirstSyncBanner)
                // Complete Google sign-in after the system browser redirects here.
                .onOpenURL { url in
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
        } else {
            LaunchLoadingView(state: startup.state, retry: startup.start)
                .environment(\.locale, resolvedLocale)
        }
    }
}

#if DEBUG
/// Opens the real chat composer with a friend whose room is unavailable, so
/// UI tests can verify a rejected send does not erase what the user typed.
private struct FriendChatUITestRoot: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var store = FriendStore(
        defaults: UserDefaults(suiteName: "FriendChatUITest-\(UUID().uuidString)")!,
        autoRefresh: false
    )
    private let friend = FriendRecord(
        id: UUID(), name: "Test friend", code: "TEST01",
        todayStudySeconds: 0, roomID: nil, isDemo: false
    )

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(colorScheme == .light ? "light" : "dark")
                    .accessibilityIdentifier("friend-chat-color-scheme")
                FriendChatView(friend: friend, store: store)
            }
        }
        .onAppear {
            store.friends = [friend]
            if ProcessInfo.processInfo.arguments.contains("--friend-chat-scroll-test") {
                store.messages = (0..<40).map { index in
                    FriendMessage(
                        id: UUID(), friendID: friend.id, text: "過去のメッセージ \(index)",
                        sentAt: Date().addingTimeInterval(Double(index - 40) * 60),
                        isMine: false, isCanceled: false
                    )
                }
            } else {
                store.messages = [FriendMessage(
                    id: UUID(), friendID: friend.id, text: "可読性テスト",
                    sentAt: Date(), isMine: false, isCanceled: false
                )]
            }
        }
    }
}

/// Hosts the real note editor with one disposable notebook and one demo
/// friend. It supplies the same `PageSnippet` notification emitted by the
/// dashed selection tool, letting UI tests cover split-screen handoff without
/// relying on Pencil coordinates or persistent user data.
private struct NoteSnippetFriendUITestRoot: View {
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var seededSnippet = false
    @StateObject private var splitState = EditorSplitState()
    @StateObject private var friendStore: FriendStore

    init() {
        AIDataDisclosure.acknowledge()
        let store = FriendStore(
            defaults: UserDefaults(suiteName: "NoteSnippetFriendUITest-\(UUID().uuidString)")!,
            autoRefresh: false
        )
        store.friends = [Self.friend]
        store.groups = [Self.group]
        _friendStore = StateObject(wrappedValue: store)
        _ = NoteSnippetFriendUITestStore.container
    }

    var body: some View {
        NoteEditorView(
            notebook: NoteSnippetFriendUITestStore.notebook,
            columnVisibility: $columnVisibility,
            onHome: {}
        )
        .modelContainer(NoteSnippetFriendUITestStore.container)
        .environmentObject(AIChatStore.shared(for: NoteSnippetFriendUITestStore.container.mainContext))
        .environmentObject(splitState)
        .environmentObject(friendStore)
        .task {
            guard !seededSnippet else { return }
            try? await Task.sleep(for: .milliseconds(600))
            seededSnippet = true
            if ProcessInfo.processInfo.arguments.contains("--note-snippet-friend-drag-ui-test") ||
                ProcessInfo.processInfo.arguments.contains("--note-snippet-group-drag-ui-test") {
                NotificationCenter.default.post(
                    name: .studiquoPageSnipped,
                    object: Self.openingSnippet
                )
                try? await Task.sleep(for: .milliseconds(800))
                NotificationCenter.default.post(
                    name: .studiquoPageSnipped,
                    object: Self.dragSnippet
                )
                return
            }
            NotificationCenter.default.post(
                name: .studiquoPageSnipped,
                object: Self.snippet
            )
        }
    }

    static let friendID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let friend = FriendRecord(
        id: friendID,
        name: "テスト太郎",
        code: "TEST01",
        todayStudySeconds: 0,
        roomID: nil,
        isDemo: true
    )
    static let group = FriendChatService.Group(
        roomID: "group-regression-room",
        name: "回帰テスト勉強会",
        members: [.init(code: "ME0000", name: "自分")]
    )

    static let snippet: PageSnippet = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160))
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 20, y: 20, width: 200, height: 120))
        }
        return PageSnippet(pngData: image.pngData()!, sourceLabel: "回帰テスト")
    }()

    static let openingSnippet = PageSnippet(
        pngData: snippet.pngData,
        sourceLabel: "準備"
    )
    static let dragSnippet = PageSnippet(
        pngData: snippet.pngData,
        sourceLabel: "ドラッグ回帰"
    )
}

@MainActor
private enum NoteSnippetFriendUITestStore {
    static let container: ModelContainer = {
        let configuration = ModelConfiguration(
            schema: studiquoSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try! ModelContainer(for: studiquoSchema, configurations: configuration)
        let notebook = Notebook(title: "切り抜き送信テスト")
        let page = NotePage(order: 0)
        page.notebook = notebook
        notebook.addPage(page)
        container.mainContext.insert(notebook)
        try! container.mainContext.save()
        return container
    }()

    static var notebook: Notebook {
        try! container.mainContext.fetch(FetchDescriptor<Notebook>()).first!
    }
}

/// Hosts the real note editor with a deterministic AI provider so UI tests can
/// pin the AIトーク behaviour (send, stop, history, drafts, delete) without a
/// network. Reachable only through the test runner's launch argument.
private struct NoteAIChatUITestRoot: View {
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @StateObject private var splitState = EditorSplitState()
    @StateObject private var friendStore: FriendStore

    init() {
        AIDataDisclosure.acknowledge()
        AI.provider = UITestAIProvider()
        let store = FriendStore(
            defaults: UserDefaults(suiteName: "NoteAIChatUITest-\(UUID().uuidString)")!,
            autoRefresh: false
        )
        _friendStore = StateObject(wrappedValue: store)
        _ = NoteAIChatUITestStore.container
    }

    var body: some View {
        NoteEditorView(
            notebook: NoteAIChatUITestStore.notebook,
            columnVisibility: $columnVisibility,
            onHome: {}
        )
        .modelContainer(NoteAIChatUITestStore.container)
        .environmentObject(AIChatStore.shared(for: NoteAIChatUITestStore.container.mainContext))
        .environmentObject(splitState)
        .environmentObject(friendStore)
        .task {
            // Opens the chat without a tap so the layout can be profiled
            // without an automation session attached.
            guard ProcessInfo.processInfo.arguments.contains("--note-ai-chat-auto-open") else { return }
            try? await Task.sleep(for: .seconds(1.5))
            NotificationCenter.default.post(
                name: .studiquoSelectAIChatTab,
                object: NoteAIChatUITestStore.seededThread.persistentModelID
            )
        }
    }
}

@MainActor
private enum NoteAIChatUITestStore {
    static var seededThread: AIChatThread {
        try! container.mainContext.fetch(FetchDescriptor<AIChatThread>()).first!
    }

    static let container: ModelContainer = {
        let configuration = ModelConfiguration(
            schema: studiquoSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try! ModelContainer(for: studiquoSchema, configurations: configuration)
        let notebook = Notebook(title: "AIトーク回帰テスト")
        let page = NotePage(order: 0)
        page.notebook = notebook
        notebook.addPage(page)
        container.mainContext.insert(notebook)
        if ProcessInfo.processInfo.arguments.contains("--note-ai-chat-auto-open") {
            let thread = AIChatThread(title: "既存の会話")
            container.mainContext.insert(thread)
            let question = AIChatMessage(text: "既存の質問", role: .user)
            question.thread = thread
            thread.addMessage(question)
            let reply = AIChatMessage(text: "既存の返答", role: .assistant)
            reply.thread = thread
            thread.addMessage(reply)
        }
        try! container.mainContext.save()
        return container
    }()

    static var notebook: Notebook {
        try! container.mainContext.fetch(FetchDescriptor<Notebook>()).first!
    }
}

/// Echoes the last user turn after a short delay. A message containing
/// "ゆっくり" streams for about thirty seconds so tests can press stop.
private struct UITestAIProvider: AIProvider {
    var isConfigured: Bool { true }
    var displayName: String { "UITest" }

    func streamChat(
        turns: [AITurn],
        noteContext: String,
        images: [UIImage],
        expectsImages: Bool,
        onDelta: @escaping (String) -> Void
    ) async throws {
        let question = turns.last(where: { $0.role == .user })?.text ?? ""
        // "sample:<id>" replies with that AI-output sample (see AIMathSamples),
        // a few characters at a time like a real streamed reply.
        if question.hasPrefix("sample:"),
           let sample = AIMathSamples.sample(id: String(question.dropFirst("sample:".count)).trimmingCharacters(in: .whitespacesAndNewlines)) {
            for piece in AIMathSamples.streamingPrefixes(of: sample.text, step: 12).enumerated().map({ index, prefix in
                String(prefix.dropFirst(index * 12))
            }) {
                try await Task.sleep(for: .milliseconds(15))
                await MainActor.run { onDelta(piece) }
            }
            return
        }
        if question.contains("ゆっくり") {
            for _ in 0..<300 {
                try await Task.sleep(for: .milliseconds(100))
                await MainActor.run { onDelta("…") }
            }
            return
        }
        // "少し待って" takes a few seconds, long enough to leave the screen first.
        try await Task.sleep(for: .milliseconds(question.contains("少し待って") ? 3000 : (question.contains("ちょっと待って") ? 1000 : 150)))
        await MainActor.run { onDelta("テスト返答: \(question)") }
    }

    func buildRubric(for submission: ProofSubmission) async throws -> ProofRubric {
        throw WorkerAIProvider.ProviderError.malformedResponse
    }

    func grade(_ submission: ProofSubmission, rubric: ProofRubric) async throws -> ProofReviewResult {
        throw WorkerAIProvider.ProviderError.malformedResponse
    }

    func researchReview(question: String, context: String) async throws -> AIReviewResult {
        AIReviewResult(isStudyRelevant: false, explanationMarkdown: "", quiz: [])
    }
}

/// Exercises the real loading view and ContentView transition with a delayed store.
private struct StartupUITestRoot: View {
    @StateObject private var loader = StartupStoreLoader<ModelContainer>(timeout: 0.05) {
        Thread.sleep(forTimeInterval: 0.15)
        let configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: studiquoSchema, configurations: configuration)
    }
    @StateObject private var authentication = AuthenticationStore(service: "com.yabuko.studiquo.startup-ui-tests")
    @StateObject private var subscriptionStore = SubscriptionStore()

    init() {
        AIDataDisclosure.acknowledge()
        UserDefaults.standard.set("", forKey: "libraryFolderNames")
        UserDefaults.standard.set(true, forKey: "didMigrateFoldersToHierarchy")
    }

    var body: some View {
        Group {
            if case .ready(let container) = loader.state {
                ContentView()
                    .modelContainer(container)
                    .environmentObject(authentication)
                    .environmentObject(subscriptionStore)
            } else {
                LaunchLoadingView(state: loader.state, retry: loader.start)
            }
        }
        .task { loader.start() }
    }
}

/// A disposable in-memory library for the drag-and-drop UI regression test.
/// It is reachable only through the test runner's launch argument.
private struct LibraryDropUITestRoot: View {
    /// Set when the test asks for a notification tap to be simulated.
    @State private var routeThreadKey: String?

    init() {
        AIDataDisclosure.acknowledge()
        // Lets UI tests drive the AIトーク (home tab and editor) without a network.
        if ProcessInfo.processInfo.arguments.contains("--ui-test-fake-ai") {
            AI.provider = UITestAIProvider()
            // Record "answer ready" notifications instead of sending real ones,
            // unless the test is about the real delivery.
            if !ProcessInfo.processInfo.arguments.contains("--ui-test-real-notifications") {
                let context = LibraryDropUITestStore.container.mainContext
                let store = AIChatStore.shared(for: context)
                let recorder = LibraryDropUITestStore.completionRecorder
                store.deliverCompletion = { recorder.delivered.append($0.title) }
                store.clearCompletion = { recorder.cleared.append($0.title) }
            }
        }
        _ = LibraryDropUITestStore.container
        if ProcessInfo.processInfo.arguments.contains("--ui-test-ai-notification-route") {
            let context = LibraryDropUITestStore.container.mainContext
            let thread = AIChatThread(title: "通知から")
            context.insert(thread)
            let question = AIChatMessage(text: "通知の質問", role: .user)
            question.thread = thread
            thread.addMessage(question)
            let reply = AIChatMessage(text: "通知の返答", role: .assistant)
            reply.thread = thread
            thread.addMessage(reply)
            try? context.save()
            _routeThreadKey = State(initialValue: AIChatStore.threadKey(thread))
        }
    }

    var body: some View {
        ContentView()
            .modelContainer(LibraryDropUITestStore.container)
            .environmentObject(LibraryDropUITestStore.authentication)
            .environmentObject(LibraryDropUITestStore.subscriptionStore)
            .overlay(alignment: .topLeading) {
                if ProcessInfo.processInfo.arguments.contains("--ui-test-fake-ai") {
                    VStack(spacing: 0) {
                        AIViewingProbe(store: AIChatStore.shared(for: LibraryDropUITestStore.container.mainContext))
                        AICompletionProbe(recorder: LibraryDropUITestStore.completionRecorder)
                    }
                }
            }
            .task {
                // The real-notification test needs the system permission.
                if ProcessInfo.processInfo.arguments.contains("--ui-test-real-notifications") {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                }
            }
            .task {
                // Simulates tapping an "answer ready" notification.
                guard let key = routeThreadKey else { return }
                try? await Task.sleep(for: .seconds(2.5))
                NotificationCenter.default.post(
                    name: .studiquoNotificationRoute,
                    object: nil,
                    userInfo: [
                        "route": AppNotificationKind.aiTaskComplete.rawValue,
                        AICompletionNotifications.threadKeyUserInfoKey: key,
                    ]
                )
            }
    }
}

/// Which "answer ready" notifications the app asked to send, and which it took back.
@MainActor
final class AICompletionRecorder: ObservableObject {
    @Published var delivered: [String] = []
    @Published var cleared: [String] = []
}

private struct AICompletionProbe: View {
    @ObservedObject var recorder: AICompletionRecorder

    var body: some View {
        Color.clear
            .frame(width: 2, height: 2)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("notified=\(recorder.delivered.joined(separator: ","));cleared=\(recorder.cleared.joined(separator: ","))")
            .accessibilityIdentifier("ai-completion-probe")
    }
}

/// A 2pt invisible element whose label says how many AI chat screens are on
/// display and which conversation is being viewed, so UI tests can check the
/// store's "is anyone looking" tracking against the real screens.
private struct AIViewingProbe: View {
    @ObservedObject var store: AIChatStore

    var body: some View {
        Color.clear
            .frame(width: 2, height: 2)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(store.debugViewingDescription)
            .accessibilityIdentifier("ai-viewing-probe")
    }
}

@MainActor
private enum LibraryDropUITestStore {
    static let completionRecorder = AICompletionRecorder()
    static let authentication = AuthenticationStore(service: "com.yabuko.studiquo.library-drop-ui-tests")
    static let subscriptionStore = SubscriptionStore()

    static let container: ModelContainer = {
        let arguments = ProcessInfo.processInfo.arguments
        let mode = arguments.contains("--column-mode") ? "column" : arguments.contains("--icon-mode") ? "icon" : "list"
        let compact = arguments.contains("--resource-types-fixture")
        UserDefaults.standard.set(mode, forKey: "homeViewMode")
        // The setting persists across UI-test launches in the simulator;
        // start each launch from the shipped default (on).
        UserDefaults.standard.set(true, forKey: ErrorReportSettings.enabledKey)
        // Notification settings persist across UI-test launches too: start from
        // "everything on, every banner on", the shipped defaults.
        UserDefaults.standard.removeObject(forKey: AppNotificationPreferences.masterDefaultsKey)
        for kind in AppNotificationKind.allCases {
            UserDefaults.standard.removeObject(forKey: kind.defaultsKey)
            UserDefaults.standard.removeObject(forKey: kind.bannerDefaultsKey)
        }
        let folderPaths = compact ? ["Target"] : ["Parent", "Parent/Source", "Parent/Destination", "Parent/Empty", "Sibling", "Target"]
        UserDefaults.standard.set(folderPaths.joined(separator: "\n"), forKey: "libraryFolderNames")
        UserDefaults.standard.set(true, forKey: "didMigrateFoldersToHierarchy")
        let persistentID = arguments
            .first(where: { $0.hasPrefix("--persistent-drop-store=") })?
            .replacingOccurrences(of: "--persistent-drop-store=", with: "")
        let configuration: ModelConfiguration
        if let persistentID {
            let storeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("LibraryDropUITest-\(persistentID).store")
            configuration = ModelConfiguration(schema: studiquoSchema, url: storeURL, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        let container = try! ModelContainer(for: studiquoSchema, configurations: configuration)
        if ((try? container.mainContext.fetchCount(FetchDescriptor<Notebook>())) ?? 0) > 0 {
            return container
        }
        let target = Folder(name: "Target")
        container.mainContext.insert(target)
        if compact {
            container.mainContext.insert(Notebook(title: "Drag me"))
            container.mainContext.insert(FlashcardDeck(title: "Cards"))
            container.mainContext.insert(TextDocument(title: "Document"))
            container.mainContext.insert(SlideDeck(title: "Y"))
            try! container.mainContext.save()
            return container
        }
        let parent = Folder(name: "Parent")
        let sourceFolder = Folder(name: "Source", parent: parent)
        let destinationFolder = Folder(name: "Destination", parent: parent)
        let emptyFolder = Folder(name: "Empty", parent: parent)
        container.mainContext.insert(parent)
        container.mainContext.insert(sourceFolder)
        container.mainContext.insert(destinationFolder)
        container.mainContext.insert(emptyFolder)
        container.mainContext.insert(Folder(name: "Sibling"))
        let source = Notebook(title: "Drag me")
        source.updatedAt = Date(timeIntervalSince1970: 100)
        container.mainContext.insert(source)
        container.mainContext.insert(Notebook(title: "Other one"))
        container.mainContext.insert(Notebook(title: "Other two"))
        container.mainContext.insert(FlashcardDeck(title: "Cards"))
        container.mainContext.insert(TextDocument(title: "Document"))
        container.mainContext.insert(SlideDeck(title: "Y"))
        let nested = Notebook(title: "Source note")
        nested.folder = sourceFolder
        nested.folderName = sourceFolder.legacyPath
        container.mainContext.insert(nested)
        let parentItem = Notebook(title: "Parent note")
        parentItem.folder = parent
        parentItem.folderName = parent.legacyPath
        container.mainContext.insert(parentItem)
        let alreadyThere = Notebook(title: "Already there")
        alreadyThere.folder = target
        alreadyThere.folderName = target.legacyPath
        container.mainContext.insert(alreadyThere)
        let pathOnly = Notebook(title: "Path only")
        pathOnly.folderName = "Target"
        container.mainContext.insert(pathOnly)
        let staleRelationship = Notebook(title: "Stale relationship")
        staleRelationship.folder = target
        container.mainContext.insert(staleRelationship)
        try! container.mainContext.save()
        return container
    }()
}

/// A disposable in-memory library, seeded with exactly one notebook, for the
/// "create a new item from the tab picker's own +" UI regression test. One
/// notebook is enough to open so the tab bar (and its own "+") becomes
/// visible — see `notebookTabBar` in ContentView.swift, which only renders
/// once something is already open.
private struct TabPickerCreateUITestRoot: View {
    @StateObject private var authentication = AuthenticationStore(service: "com.yabuko.studiquo.tab-picker-create-ui-tests")
    @StateObject private var subscriptionStore = SubscriptionStore()

    init() {
        AIDataDisclosure.acknowledge()
        UserDefaults.standard.set("", forKey: "libraryFolderNames")
        UserDefaults.standard.set(true, forKey: "didMigrateFoldersToHierarchy")
        _ = TabPickerCreateUITestStore.container
    }

    var body: some View {
        ContentView()
            .modelContainer(TabPickerCreateUITestStore.container)
            .environmentObject(authentication)
            .environmentObject(subscriptionStore)
    }
}

@MainActor
private enum TabPickerCreateUITestStore {
    static let container: ModelContainer = {
        let configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try! ModelContainer(for: studiquoSchema, configurations: configuration)
        let notebook = Notebook(title: "既存のノート")
        let page = NotePage(order: 0)
        page.notebook = notebook
        notebook.addPage(page)
        container.mainContext.insert(notebook)
        try! container.mainContext.save()
        return container
    }()
}
#endif

private struct LaunchLoadingView: View {
    let state: StartupStoreLoader<ModelContainer>.State
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "book.pages.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            switch state {
            case .delayed:
                Text("データの読み込みに時間がかかっています")
                    .font(.headline)
                Text("読み込みが完了すると自動的に画面が切り替わります。改善しない場合は、アプリを終了して開き直してください。保存済みのデータは削除されません。")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text("保存データを開けませんでした")
                    .font(.headline)
                Text("保存済みのデータは削除されていません。もう一度お試しください。")
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("再試行", action: retry)
                    .buttonStyle(.borderedProminent)
            default:
                ProgressView()
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

/// Tracks whether this device's very first CloudKit hand-off (schema push +
/// initial import) is still in flight, so the UI can show a brief, dismissible
/// hint instead of silently waiting for notes to appear from other devices.
/// Never blocks app launch; CloudKit sync runs in the background.
@MainActor
/// Reports iCloud sync failures that point at a real problem. Being offline,
/// signed out of iCloud or rate-limited is ordinary and not worth a report.
enum CloudKitErrorReporting {
    /// CKError codes for conditions the person or the network causes:
    /// networkUnavailable, networkFailure, serviceUnavailable,
    /// requestRateLimited, notAuthenticated, zoneBusy.
    nonisolated static let ignoredCKErrorCodes: Set<Int> = [3, 4, 6, 7, 9, 23]

    nonisolated static func shouldReport(domain: String, code: Int) -> Bool {
        !(domain == CKErrorDomain && ignoredCKErrorCodes.contains(code))
    }

    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event,
                event.endDate != nil, let error = event.error as NSError?,
                shouldReport(domain: error.domain, code: error.code) else { return }
            ErrorReportService.recordFailure(area: "iCloud同期", error: error)
        }
    }
}

private final class CloudKitSyncStatus: ObservableObject {
    private static let hasCompletedFirstSyncKey = "hasCompletedFirstCloudKitSync"
    /// Safety net for accounts that never get a CloudKit event at all (no
    /// iCloud sign-in, iCloud Drive disabled, long-term offline) — the banner
    /// must not linger forever in that case.
    private static let timeoutSeconds: UInt64 = 15

    @Published private(set) var isShowingFirstSyncBanner = false

    private var observer: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?

    init() {
        guard !UserDefaults.standard.bool(forKey: Self.hasCompletedFirstSyncKey) else { return }
        isShowingFirstSyncBanner = true

        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event,
                event.type == .import, event.endDate != nil else { return }
            // `queue: .main` above already guarantees this runs on the main
            // thread; hopping through a `Task` just satisfies the compiler's
            // static actor-isolation check for this non-isolated closure type.
            Task { @MainActor in self?.finishFirstSync() }
        }

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.timeoutSeconds * 1_000_000_000)
            self?.finishFirstSync()
        }
    }

    private func finishFirstSync() {
        guard isShowingFirstSyncBanner else { return }
        isShowingFirstSyncBanner = false
        UserDefaults.standard.set(true, forKey: Self.hasCompletedFirstSyncKey)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }
}

private struct FirstCloudSyncBanner: View {
    var body: some View {
        Label(L("iCloudと同期しています…"), systemImage: "icloud.and.arrow.down")
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
    }
}
