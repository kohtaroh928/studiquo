import XCTest
@testable import studiquo

final class AIModelCatalogTests: XCTestCase {
    func testStandardPlanOnlyUnlocksTheFreeGeminiModel() {
        let available = AIModelCatalog.availableModels(for: .standard).map(\.id)
        XCTAssertEqual(available, [.geminiFlashLite])
    }

    func testPlusPlanUnlocksEveryStandardAndPlusModelButNotProModels() {
        let available = Set(AIModelCatalog.availableModels(for: .plus).map(\.id))
        XCTAssertEqual(available, [.geminiFlashLite, .claudeHaiku, .claudeSonnet, .openAIMid])
        XCTAssertFalse(available.contains(.claudeOpus))
        XCTAssertFalse(available.contains(.openAIFlagship))
    }

    func testProPlanUnlocksEveryModelInTheCatalog() {
        let available = Set(AIModelCatalog.availableModels(for: .pro).map(\.id))
        XCTAssertEqual(available, Set(AIModelID.allCases))
    }

    func testIsAvailableMatchesTheRequiredPlanExactly() {
        XCTAssertTrue(AIModelCatalog.isAvailable(.geminiFlashLite, for: .standard))
        XCTAssertFalse(AIModelCatalog.isAvailable(.claudeHaiku, for: .standard))
        XCTAssertTrue(AIModelCatalog.isAvailable(.claudeHaiku, for: .plus))
        XCTAssertFalse(AIModelCatalog.isAvailable(.claudeOpus, for: .plus))
        XCTAssertTrue(AIModelCatalog.isAvailable(.claudeOpus, for: .pro))
    }

    func testDefaultModelIsAlwaysAvailableOnEveryPlan() {
        for plan in StudiquoPlan.allCases {
            XCTAssertTrue(AIModelCatalog.isAvailable(AIModelCatalog.defaultModel, for: plan))
        }
    }

    /// Regression coverage for the one thing that must never silently drift:
    /// the raw string sent to the Worker in the `"model"` field has to match
    /// `mcp-server/src/ai.js`'s `PLAN_MODELS` table exactly (see
    /// `AIModelID`'s own doc comment on why these are hand-synced).
    func testEveryModelIDRawValueMatchesTheAgreedWorkerContract() {
        XCTAssertEqual(AIModelID.geminiFlashLite.rawValue, "gemini-3.5-flash-lite")
        XCTAssertEqual(AIModelID.claudeHaiku.rawValue, "claude-haiku-4-5-20251001")
        XCTAssertEqual(AIModelID.claudeSonnet.rawValue, "claude-sonnet-5")
        XCTAssertEqual(AIModelID.claudeOpus.rawValue, "claude-opus-5-5")
    }

    func testEveryCatalogEntryHasAMatchingAIModelIDCase() {
        XCTAssertEqual(Set(AIModelCatalog.all.map(\.id)), Set(AIModelID.allCases))
    }

    func testAIModelSelectionPersistsAcrossReadsViaUserDefaults() {
        let original = AIModelSelection.current
        defer { AIModelSelection.current = original }

        AIModelSelection.current = .claudeSonnet
        XCTAssertEqual(AIModelSelection.current, .claudeSonnet)

        AIModelSelection.current = .claudeOpus
        XCTAssertEqual(AIModelSelection.current, .claudeOpus)
    }
}
