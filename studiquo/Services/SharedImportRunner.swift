import Foundation

/// Imports the files the student chose a destination for, one at a time.
///
/// This is the batch's rules, kept apart from the screen so they can be tested:
/// - only the files handed in are touched — never leftovers from earlier
///   failures, which stay held for their own retry;
/// - one file failing never stops the others (a later, smaller one may well
///   succeed);
/// - files are processed strictly one after another, because each PDF is a
///   large render and a locked one waits for its password;
/// - what could not be imported is held for a later retry, and the result is
///   reported once at the end rather than as one alert per file.
@MainActor
enum SharedImportRunner {
    enum Outcome {
        case imported
        /// Could not be imported this time; it stays in the inbox, held.
        case failed
    }

    /// `importer` does the actual work for one file and returns how it went. It
    /// is awaited to completion before the next file starts.
    ///
    /// The caller must have called `coordinator.begin(total:)` already, in the
    /// same synchronous step as the tap that started the import. Starting it
    /// here, inside the async task, would leave a gap in which a second tap
    /// begins a second run over the same files. Without it this returns `nil`.
    static func run(
        items: [SharedInbox.Item],
        coordinator: SharedImportCoordinator,
        importer: (SharedInbox.Item) async -> Outcome
    ) async -> SharedImportSummary? {
        guard coordinator.isImporting else { return nil }
        var unsupported: [String] = []
        var failed: [SharedInbox.Item] = []

        for (index, item) in items.enumerated() {
            coordinator.advance(completed: index, currentName: item.displayName)
            guard SharedInbox.isImportable(item.url) else {
                unsupported.append(item.displayName)
                coordinator.finish(item)
                continue
            }
            switch await importer(item) {
            case .imported:
                coordinator.finish(item)
            case .failed:
                failed.append(item)
            }
            // Let the screen draw the finished file before the next render starts.
            await Task.yield()
        }

        coordinator.end(attempted: failed)
        return SharedImportSummary(
            imported: items.count - unsupported.count - failed.count,
            unsupported: unsupported,
            held: failed.map(\.displayName)
        )
    }
}
