import CoreData
import OSLog
import GoogleSignIn
import SwiftUI
import SwiftData

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
])

private let startupLogger = Logger(subsystem: "com.yabuko.studiquo", category: "Startup")

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
    @StateObject private var startup = StartupStoreLoader(openStore: makeStudiquoModelContainer)
    @AppStorage("appLanguage") private var appLanguage = "system"
    @StateObject private var cloudSyncStatus = CloudKitSyncStatus()

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
                      !ProcessInfo.processInfo.arguments.contains("--friend-chat-ui-test") else { return }
                #endif
                startup.start()
            }
        }
    }

    @ViewBuilder private var normalRoot: some View {
        if case .ready(let modelContainer) = startup.state {
            AccountGateView()
                .modelContainer(modelContainer)
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
            store.messages = [FriendMessage(
                id: UUID(), friendID: friend.id, text: "可読性テスト",
                sentAt: Date(), isMine: false, isCanceled: false
            )]
        }
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
    init() {
        AIDataDisclosure.acknowledge()
        _ = LibraryDropUITestStore.container
    }

    var body: some View {
        ContentView()
            .modelContainer(LibraryDropUITestStore.container)
            .environmentObject(LibraryDropUITestStore.authentication)
    }
}

@MainActor
private enum LibraryDropUITestStore {
    static let authentication = AuthenticationStore(service: "com.yabuko.studiquo.library-drop-ui-tests")

    static let container: ModelContainer = {
        let arguments = ProcessInfo.processInfo.arguments
        let mode = arguments.contains("--column-mode") ? "column" : "list"
        let compact = arguments.contains("--resource-types-fixture")
        UserDefaults.standard.set(mode, forKey: "homeViewMode")
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
