import UIKit
import XCTest
@testable import studiquo

/// Legacy direct Anthropic grading is not an approved initial-release route.
final class ProofGradingServiceTests: XCTestCase {
    func testEmptyModelAnswerIsRejectedBeforeNetworking() async {
        do {
            _ = try await ProofGradingService.buildRubric(question: "Q", modelAnswer: " \n ", apiKey: "test-key")
            XCTFail("Expected missingModelAnswer")
        } catch ProofGradingService.GradingError.missingModelAnswer {} catch { XCTFail("Unexpected: \(error)") }
    }

    func testLegacyRubricRequestCannotReachUnapprovedProvider() async {
        do {
            _ = try await ProofGradingService.buildRubric(question: "Q", modelAnswer: "A", apiKey: "test-key", session: rejectingSession())
            XCTFail("Expected providerUnavailable")
        } catch WorkerAIProvider.ProviderError.providerUnavailable {} catch { XCTFail("Unexpected: \(error)") }
    }

    func testLegacyImageGradingCannotReachUnapprovedProvider() async {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        do {
            _ = try await ProofGradingService.grade(answerImage: image, question: "Q", rubric: ProofRubric(criteria: []), apiKey: "test-key", session: rejectingSession())
            XCTFail("Expected providerUnavailable")
        } catch WorkerAIProvider.ProviderError.providerUnavailable {} catch { XCTFail("Unexpected: \(error)") }
    }

    func testRubricAndReviewModelsStillDecodeStructuredResults() throws {
        let rubric = try JSONDecoder().decode(ProofRubric.self, from: Data(#"{"criteria":[{"name":"Logic","maxPoints":100,"requirement":"Explain"}]}"#.utf8))
        XCTAssertEqual(rubric.totalPoints, 100)
        let result = try JSONDecoder().decode(ProofReviewResult.self, from: Data(#"{"score":75,"maxScore":100,"verdict":"Good","criteria":[],"issues":[{"step":2,"kindRawValue":"logical_gap","excerpt":"therefore","explanation":"Missing","suggestion":"Explain"}]}"#.utf8))
        XCTAssertEqual(result.percentage, 75)
        XCTAssertEqual(result.issues.first?.kind, .logicalGap)
    }

    private func rejectingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnexpectedGradingRequest.self]
        return URLSession(configuration: configuration)
    }
}

private final class UnexpectedGradingRequest: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Unapproved processor must not receive a network request")
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}
