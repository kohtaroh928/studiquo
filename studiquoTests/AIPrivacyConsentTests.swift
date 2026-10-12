import XCTest
@testable import studiquo

final class AIPrivacyConsentTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "AIPrivacyConsentTests-\(UUID().uuidString)"
        AIDataDisclosure.defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        AIDataDisclosure.defaults.removePersistentDomain(forName: suiteName)
        AIDataDisclosure.defaults = .standard
        super.tearDown()
    }

    func testLegacyAcknowledgementDoesNotAuthorizeNewDisclosure() {
        AIDataDisclosure.defaults.set(true, forKey: AIDataDisclosure.acknowledgedDefaultsKey)
        XCTAssertFalse(AIDataDisclosure.hasBeenAcknowledged)
        XCTAssertFalse(AIDataDisclosure.hasMadeDecision)
    }

    func testDeclineAllowsDecisionToPersistWithoutAuthorizingTransmission() {
        AIDataDisclosure.revoke()
        XCTAssertTrue(AIDataDisclosure.hasMadeDecision)
        XCTAssertFalse(AIDataDisclosure.hasBeenAcknowledged)
        XCTAssertThrowsError(try WorkerAIProvider().request(path: "api/ai/chat", body: [:])) { error in
            guard case WorkerAIProvider.ProviderError.consentRequired = error else {
                return XCTFail("Expected consent rejection before request construction")
            }
        }
    }

    func testConsentIsVersionedAndRevocationDisablesAutomaticReview() throws {
        AIDataDisclosure.acknowledge(ageBand: .adult)
        let request = try WorkerAIProvider().request(path: "api/ai/chat", body: [:])
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Studiquo-AI-Consent"), "openai-v1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Studiquo-Age"), "adult")
        AIDataDisclosure.defaults.set(true, forKey: AIReviewService.isEnabledDefaultsKey)
        AIDataDisclosure.revoke()
        XCTAssertFalse(AIDataDisclosure.hasBeenAcknowledged)
        XCTAssertFalse(AIDataDisclosure.defaults.bool(forKey: AIReviewService.isEnabledDefaultsKey))
        XCTAssertThrowsError(try WorkerAIProvider().request(path: "api/ai/review", body: [:]))
    }

    func testOlderVersionRequiresFreshPermission() {
        AIDataDisclosure.defaults.set("google-v2", forKey: AIDataDisclosure.consentVersionDefaultsKey)
        AIDataDisclosure.defaults.set("google-v2", forKey: AIDataDisclosure.decisionVersionDefaultsKey)
        XCTAssertFalse(AIDataDisclosure.hasBeenAcknowledged)
        XCTAssertFalse(AIDataDisclosure.hasMadeDecision)
    }

    func testTeenBandIsSentAndAConsentWithoutAnAgeBandIsNotValid() throws {
        AIDataDisclosure.acknowledge(ageBand: .teen)
        let request = try WorkerAIProvider().request(path: "api/ai/chat", body: [:])
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Studiquo-Age"), "teen")
        AIDataDisclosure.defaults.removeObject(forKey: AIDataDisclosure.ageBandDefaultsKey)
        XCTAssertFalse(AIDataDisclosure.hasBeenAcknowledged)
        XCTAssertThrowsError(try WorkerAIProvider().request(path: "api/ai/chat", body: [:]))
    }

    func testRevokingForgetsTheAgeBand() {
        AIDataDisclosure.acknowledge(ageBand: .teen)
        AIDataDisclosure.revoke()
        XCTAssertNil(AIDataDisclosure.ageBand)
    }

    func testOnlyOneProcessorIsOfferedAndDirectIntegrationsAreDisabled() {
        XCTAssertEqual(Set(AIModelCatalog.offered.map(\.providerName)), ["OpenAI"])
        XCTAssertFalse(AIDataDisclosure.allowsDirectProviders)
    }
}
