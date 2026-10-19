import Foundation
import WebKit

extension Notification.Name {
    /// Posted after the in-app browser's website data was erased, so an open
    /// browser tab can drop the page it was showing.
    static let studiquoBrowserDataErased = Notification.Name("studiquoBrowserDataErased")
}

/// Erases what the in-app browser keeps: cookies, local storage, caches, saved
/// sign-ins of the sites the student visited (a school's learning system, a
/// Google account). The browser uses the persistent data store, so without this
/// they would outlive the student's sign-out from Studiquo, and the deletion of
/// their account, and be there for the next person who signs in on the device.
@MainActor
enum BrowserDataEraser {
    static func eraseAll(
        store: WKWebsiteDataStore = .default(),
        center: NotificationCenter = .default
    ) async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        center.post(name: .studiquoBrowserDataErased, object: nil)
    }
}
