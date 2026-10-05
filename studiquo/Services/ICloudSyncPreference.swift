import Foundation
import SwiftData

/// Whether this device mirrors its library to iCloud (CloudKit).
///
/// One switch for the whole device: the library lives in a single store, and
/// CloudKit mirroring is all-or-nothing per store — individual notes cannot be
/// opted in or out.
///
/// New installs start with sync off. Anyone who already has a library keeps the
/// sync they had, so an update never silently cuts a device off from the others.
/// The store is opened once at launch, so a change applies after the app is
/// quit and reopened.
enum ICloudSyncPreference {
    static let defaultsKey = "iCloudSyncEnabled"

    /// The stored choice. The very first time it is read, it is decided from
    /// whether a library already exists, and written back so it never changes
    /// by itself afterwards.
    static func resolve(defaults: UserDefaults = .standard, existingStoreFound: Bool) -> Bool {
        if let stored = defaults.object(forKey: defaultsKey) as? Bool { return stored }
        defaults.set(existingStoreFound, forKey: defaultsKey)
        return existingStoreFound
    }

    /// True when the default SwiftData store is already on disk.
    static func defaultStoreExists(fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: ModelConfiguration(schema: studiquoSchema).url.path)
    }

    /// Decided exactly once per launch, before the store is opened (a `static let`
    /// is initialised lazily and thread-safely, so it does not matter whether
    /// the first caller is the app's `init` or the background store loader).
    /// A store file created *after* this point must not make a brand-new
    /// install look like an existing one.
    private static let launchValue: Bool = resolve(existingStoreFound: defaultStoreExists())

    /// Call first thing at startup so the decision is made before anything
    /// can create the store file.
    @discardableResult
    static func resolveAtLaunch() -> Bool { launchValue }

    /// What the store was opened with at launch.
    static var isEnabledAtLaunch: Bool { launchValue }

    /// What the student has chosen, which may differ until the next launch.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? isEnabledAtLaunch
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }

    static var needsRestart: Bool { isEnabled != isEnabledAtLaunch }
}
