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
        ])
        do {
            let cloudConfiguration = ModelConfiguration(
                schema: schema,
                cloudKitDatabase: .automatic
            )
            sharedModelContainer = try ModelContainer(for: schema, configurations: cloudConfiguration)
        } catch {
            // Development simulators and devices without an iCloud account
            // must remain usable and must keep the existing local store.
            let localConfiguration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            sharedModelContainer = try! ModelContainer(for: schema, configurations: localConfiguration)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(Color(red: 0.16, green: 0.33, blue: 0.63))
                .environment(\.locale, resolvedLocale)
        }
        .modelContainer(sharedModelContainer)
    }
}
