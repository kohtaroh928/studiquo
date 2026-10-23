import Foundation

/// Persist only control/retry metadata, never extracted text, titles, images or credentials.
struct RAGLibrarySyncState: Codable {
    enum Scope: Codable, Equatable { case allPDFs, folder(String), selected([String]) }
    struct Entry: Codable {
        var fingerprint: String = ""
        var sourceHash: String = ""
        var sourceId: String? = nil
        var generation: Int = 0
        var requestId: String = ""
        var expectedGeneration: Int = 0
        var nextPage: Int = 0
        var completed: Bool = false
        var searchState: String? = nil
        var readinessAttempts: Int? = nil
        var readinessAfter: Date? = nil
        var retryAfter: Date? = nil
        var retryAttempts: Int? = nil
        var restoreRequested: Bool? = nil
        var settledState: String? = nil
        var pendingState: String? = nil
    }
    var processorConsentVersion: String? = nil
    var enabled = false
    var consentEpoch = 0
    var pendingRevoke = false
    var controlRetryAfter: Date? = nil
    var controlRetryAttempts: Int? = nil
    var scope: Scope = .selected([])
    var includeFuture = false
    var selectedAtGrant: [String] = []
    var excluded: [String] = []
    var entries: [String: Entry] = [:]
}
