import XCTest
@testable import studiquo

final class AIModelCatalogTests: XCTestCase {
    func testStandardPlanOnlyUnlocksTheBaseModel() {
        let available = AIModelCatalog.availableModels(for: .standard).map(\.id)
        XCTAssertEqual(available, [.openAILuna])
    }

    func testPlusPlanUnlocksStandardAndPlusModelsButNotProModels() {
        let available = Set(AIModelCatalog.availableModels(for: .plus).map(\.id))
        XCTAssertEqual(available, [.openAILuna, .openAITerra, .openAISol])
        XCTAssertFalse(available.contains(.openAIAstra))
    }

    func testProPlanUnlocksEveryModelInTheCatalog() {
        let available = Set(AIModelCatalog.availableModels(for: .pro).map(\.id))
        XCTAssertEqual(available, Set(AIModelID.allCases))
    }

    func testIsAvailableMatchesTheRequiredPlanExactly() {
        XCTAssertTrue(AIModelCatalog.isAvailable(.openAILuna, for: .standard))
        XCTAssertFalse(AIModelCatalog.isAvailable(.openAISol, for: .standard))
        XCTAssertTrue(AIModelCatalog.isAvailable(.openAISol, for: .plus))
        XCTAssertFalse(AIModelCatalog.isAvailable(.openAIAstra, for: .plus))
        XCTAssertTrue(AIModelCatalog.isAvailable(.openAIAstra, for: .pro))
    }

    func testNoModelIsAvailableWithoutAPlan() {
        XCTAssertTrue(AIModelCatalog.availableModels(for: .free).isEmpty)
    }

    func testDefaultModelIsAlwaysAvailableOnEveryPlan() {
        for plan in StudiquoPlan.allCases where plan >= .standard {
            XCTAssertTrue(AIModelCatalog.isAvailable(AIModelCatalog.defaultModel, for: plan))
        }
    }

    /// The raw string sent to the Worker in the `"model"` field has to match
    /// `mcp-server/src/ai.js`'s `PLAN_MODELS` table exactly.
    func testEveryModelIDRawValueMatchesTheAgreedWorkerContract() {
        XCTAssertEqual(AIModelID.openAILuna.rawValue, "openai-luna")
        XCTAssertEqual(AIModelID.openAITerra.rawValue, "openai-terra")
        XCTAssertEqual(AIModelID.openAISol.rawValue, "openai-sol")
        XCTAssertEqual(AIModelID.openAIAstra.rawValue, "openai-astra")
    }

    /// The Worker's `MODEL_CREDITS` (`mcp-server/src/ai-credits.js`).
    func testCreditsPerModelMatchTheWorkersWeights() {
        let credits = Dictionary(uniqueKeysWithValues: AIModelCatalog.all.map { ($0.id, $0.credits) })
        XCTAssertEqual(credits, [.openAILuna: 1, .openAISol: 20, .openAITerra: 22, .openAIAstra: 100])
    }

    func testEveryModelIsOffered() {
        XCTAssertEqual(AIModelCatalog.offered.map(\.id), AIModelCatalog.all.map(\.id))
        XCTAssertTrue(AIModelCatalog.offered.allSatisfy { $0.providerName == "OpenAI" })
    }

    func testEveryCatalogEntryHasAMatchingAIModelIDCase() {
        XCTAssertEqual(Set(AIModelCatalog.all.map(\.id)), Set(AIModelID.allCases))
    }

    func testASavedSelectionFromAnEarlierProviderFallsBackToTheBaseModel() {
        let original = AIModelSelection.current
        defer { AIModelSelection.current = original }

        UserDefaults.standard.set("gemini-3.5-flash-lite", forKey: AIModelSelection.defaultsKey)
        XCTAssertEqual(AIModelSelection.current, .openAILuna)
        UserDefaults.standard.set("claude-opus-5-5", forKey: AIModelSelection.defaultsKey)
        XCTAssertEqual(AIModelSelection.current, .openAILuna)
        AIModelSelection.current = .openAISol
        XCTAssertEqual(AIModelSelection.current, .openAISol)
    }
}
