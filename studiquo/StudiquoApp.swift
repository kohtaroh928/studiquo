import CoreData
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

@main
struct StudiquoApp: App {
    private let sharedModelContainer: ModelContainer
    @AppStorage("appLanguage") private var appLanguage = "system"
    @StateObject private var cloudSyncStatus = CloudKitSyncStatus()

    private var resolvedLocale: Locale {
        switch appLanguage {
        case "japanese": Locale(identifier: "ja")
        case "english": Locale(identifier: "en")
        default: Locale.autoupdatingCurrent
        }
    }

    init() {
        let schema = Schema([
            Notebook.self, NotePage.self, PageElement.self,
            FlashcardDeck.self, Flashcard.self, CalendarEvent.self, StudyActivity.self,
            AIChatThread.self, AIChatMessage.self,
            TextDocument.self, SlideDeck.self, Slide.self,
        ])
        do {
            // Creating a CloudKit-backed container does not itself wait on the
            // network: it opens the local store synchronously (fast, as with
            // the old local-only configuration) and CloudKit's own one-time
            // schema push and ongoing sync happen in the background afterward,
            // surfaced to the UI via `CloudKitSyncStatus` rather than by
            // blocking this call.
            let cloudConfiguration = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
            sharedModelContainer = try ModelContainer(for: schema, configurations: cloudConfiguration)
        } catch {
            do {
                // CloudKit unavailable for this launch (offline, no iCloud
                // account, schema push failed, etc.) — fall back to a
                // local-only store so the user's data still persists even
                // though it won't sync across devices until CloudKit is
                // reachable again on a later launch.
                let localConfiguration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
                sharedModelContainer = try ModelContainer(for: schema, configurations: localConfiguration)
            } catch {
                // If even the local persistent store cannot be opened after a
                // schema change, still show the app instead of leaving the
                // user on a blank screen.
                let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                sharedModelContainer = try! ModelContainer(for: schema, configurations: fallback)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            AccountGateView()
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
                // Google's sign-in flow completes in Safari/the system
                // browser and hands control back to the app via this app's
                // reversed-client-id URL scheme (Info.plist) — GIDSignIn
                // needs that redirect to finish the flow it started.
                .onOpenURL { url in
                    _ = GIDSignIn.sharedInstance.handle(url)
                }
        }
        .modelContainer(sharedModelContainer)
    }
}

/// Tracks whether this device's very first CloudKit hand-off (schema push +
/// initial import) is still in flight, so the UI can show a brief, dismissible
/// hint instead of silently waiting for notes to appear from other devices.
/// Never blocks app launch — `StudiquoApp.init()` already returns before this
/// finishes, since CloudKit sync runs in the background regardless.
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
