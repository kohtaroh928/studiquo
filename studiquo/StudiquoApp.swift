import SwiftUI
import SwiftData

@main
struct StudiquoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(Color(red: 0.16, green: 0.33, blue: 0.63))
        }
        .modelContainer(for: [Notebook.self, NotePage.self, PageElement.self, FlashcardDeck.self, Flashcard.self])
    }
}
