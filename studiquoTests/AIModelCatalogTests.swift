import XCTest
@testable import studiquo

final class AIModelCatalogTests: XCTestCase {
    func testStandardPlanOnlyUnlocksTheFreeGeminiModel() {
        let available = AIModelCatalog.availableModels(for: .standard).map(\.id)
        XCTAssertEqual(available, [.geminiFlashLite])
    }

    func testPlusPlanUnlocksEveryStandardAndPlusModelButNotProModels() {
        let available = Set(AIModelCatalog.availableModels(for: .plus).map(\.id))
        XCTAssertEqual(available, [.geminiFlashLite, .claudeSonnet, .openAILuna, .openAITerra, .openAISol])
        XCTAssertFalse(available.contains(.claudeOpus))
        XCTAssertFalse(available.contains(.openAIAstra))
    }

    func testProPlanUnlocksEveryModelInTheCatalog() {
        let available = Set(AIModelCatalog.availableModels(for: .pro).map(\.id))
        XCTAssertEqual(available, Set(AIModelID.allCases))
    }

    func testIsAvailableMatchesTheRequiredPlanExactly() {
        XCTAssertTrue(AIModelCatalog.isAvailable(.geminiFlashLite, for: .standard))
        XCTAssertFalse(AIModelCatalog.isAvailable(.claudeSonnet, for: .standard))
        XCTAssertTrue(AIModelCatalog.isAvailable(.claudeSonnet, for: .plus))
        XCTAssertFalse(AIModelCatalog.isAvailable(.claudeOpus, for: .plus))
        XCTAssertTrue(AIModelCatalog.isAvailable(.claudeOpus, for: .pro))
    }

    func testNoModelIsAvailableWithoutAPlan() {
        XCTAssertTrue(AIModelCatalog.availableModels(for: .free).isEmpty)
    }

    func testDefaultModelIsAlwaysAvailableOnEveryPlan() {
        for plan in StudiquoPlan.allCases where plan >= .standard {
            XCTAssertTrue(AIModelCatalog.isAvailable(AIModelCatalog.defaultModel, for: plan))
        }
    }

    /// Regression coverage for the one thing that must never silently drift:
    /// the raw string sent to the Worker in the `"model"` field has to match
    /// `mcp-server/src/ai.js`'s `PLAN_MODELS` table exactly (see
    /// `AIModelID`'s own doc comment on why these are hand-synced).
    func testEveryModelIDRawValueMatchesTheAgreedWorkerContract() {
        XCTAssertEqual(AIModelID.geminiFlashLite.rawValue, "gemini-3.5-flash-lite")
        XCTAssertEqual(AIModelID.claudeSonnet.rawValue, "claude-sonnet-5-5")
        XCTAssertEqual(AIModelID.claudeOpus.rawValue, "claude-opus-5-5")
        XCTAssertEqual(AIModelID.openAILuna.rawValue, "openai-luna")
        XCTAssertEqual(AIModelID.openAITerra.rawValue, "openai-terra")
        XCTAssertEqual(AIModelID.openAISol.rawValue, "openai-sol")
        XCTAssertEqual(AIModelID.openAIAstra.rawValue, "openai-astra")
    }

    /// The Worker's `MODEL_CREDITS` (`mcp-server/src/ai-credits.js`).
    func testCreditsPerModelMatchTheWorkersWeights() {
        let credits = Dictionary(uniqueKeysWithValues: AIModelCatalog.all.map { ($0.id, $0.credits) })
        XCTAssertEqual(credits, [
            .geminiFlashLite: 1, .openAILuna: 1, .claudeSonnet: 20, .openAISol: 20,
            .openAITerra: 22, .claudeOpus: 40, .openAIAstra: 100,
        ])
    }

    func testPlusAndProModelsMatchThePublishedPlan() {
        func ids(_ plan: StudiquoPlan) -> Set<AIModelID> { Set(AIModelCatalog.availableModels(for: plan).map(\.id)) }
        XCTAssertEqual(ids(.standard), [.geminiFlashLite])
        XCTAssertEqual(ids(.plus), [.geminiFlashLite, .claudeSonnet, .openAILuna, .openAITerra, .openAISol])
        XCTAssertEqual(ids(.pro), ids(.plus).union([.claudeOpus, .openAIAstra]))
    }

    func testOtherProvidersStayHiddenUntilTheyAreExplicitlyEnabled() {
        XCTAssertFalse(AIModelCatalog.thirdPartyModelsEnabled)
        XCTAssertEqual(AIModelCatalog.offered.map(\.id), [.geminiFlashLite])
    }

    func testEveryCatalogEntryHasAMatchingAIModelIDCase() {
        XCTAssertEqual(Set(AIModelCatalog.all.map(\.id)), Set(AIModelID.allCases))
    }

    func testInitialReleaseDoesNotSendToPreviouslySelectedOtherProviders() {
        let original = AIModelSelection.current
        defer { AIModelSelection.current = original }

        AIModelSelection.current = .claudeSonnet
        XCTAssertEqual(AIModelSelection.current, .geminiFlashLite)

        AIModelSelection.current = .claudeOpus
        XCTAssertEqual(AIModelSelection.current, .geminiFlashLite)
    }
}
