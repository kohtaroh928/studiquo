import UIKit
import XCTest
@testable import studiquo

final class ProofGradingServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ProofGradingURLProtocol.reset()
    }

    func testEmptyModelAnswerIsRejectedBeforeNetworking() async {
        do {
            _ = try await ProofGradingService.buildRubric(
                question: "Prove it",
                modelAnswer: "  \n ",
                apiKey: "test-key",
                session: makeSession()
            )
            XCTFail("Expected missingModelAnswer")
        } catch ProofGradingService.GradingError.missingModelAnswer {
            XCTAssertNil(ProofGradingURLProtocol.request)
        } catch {
            XCTFail("Expected missingModelAnswer, got \(error)")
        }
    }

    func testMissingAPIKeyIsRejectedBeforeNetworking() async {
        do {
            _ = try await ProofGradingService.buildRubric(
                question: "Prove it",
                modelAnswer: "A valid proof",
                apiKey: nil,
                session: makeSession()
            )
            XCTFail("Expected missingKey")
        } catch ProofGradingService.GradingError.missingKey {
            XCTAssertNil(ProofGradingURLProtocol.request)
        } catch {
            XCTFail("Expected missingKey, got \(error)")
        }
    }

    func testBuildRubricDecodesTextBlockAndSendsStructuredOutputRequest() async throws {
        let rubricJSON = #"{"criteria":[{"name":"Definition","maxPoints":40,"requirement":"State the definition"},{"name":"Conclusion","maxPoints":60,"requirement":"Reach the claim"}]}"#
        ProofGradingURLProtocol.respond(status: 200, object: [
            "content": [
                ["type": "thinking", "thinking": "internal"],
                ["type": "text", "text": rubricJSON],
            ]
        ])

        let rubric = try await ProofGradingService.buildRubric(
            question: "  Prove P  ",
            modelAnswer: "  Proof of P  ",
            apiKey: "test-key",
            session: makeSession()
        )

        XCTAssertEqual(rubric.totalPoints, 100)
        XCTAssertEqual(rubric.criteria.map(\.name), ["Definition", "Conclusion"])
        let request = try XCTUnwrap(ProofGradingURLProtocol.request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let body = try requestJSON()
        XCTAssertEqual(body["model"] as? String, "claude-opus-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 16_000)
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        let output = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "high")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let prompt = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(prompt.contains("<問題>\nProve P\n</問題>"))
        XCTAssertTrue(prompt.contains("<模範解答>\nProof of P\n</模範解答>"))
    }

    func testGradeSendsPNGAndDecodesReview() async throws {
        let resultJSON = #"{"score":75,"maxScore":100,"verdict":"Good start","criteria":[{"name":"Logic","earnedPoints":75,"maxPoints":100,"comment":"Mostly sound"}],"issues":[{"step":2,"kindRawValue":"logical_gap","excerpt":"therefore","explanation":"A step is missing","suggestion":"Add the implication"}]}"#
        ProofGradingURLProtocol.respond(status: 200, object: [
            "content": [["type": "text", "text": resultJSON]]
        ])
        let rubric = ProofRubric(criteria: [
            ProofCriterion(name: "Logic", maxPoints: 100, requirement: "Every implication is justified")
        ])

        let result = try await ProofGradingService.grade(
            answerImage: image(),
            question: "Prove P",
            rubric: rubric,
            apiKey: "test-key",
            session: makeSession()
        )

        XCTAssertEqual(result.score, 75)
        XCTAssertEqual(result.percentage, 75)
        XCTAssertEqual(result.issues.first?.kind, .logicalGap)
        let body = try requestJSON()
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let imageBlock = try XCTUnwrap(content.first)
        XCTAssertEqual(imageBlock["type"] as? String, "image")
        let source = try XCTUnwrap(imageBlock["source"] as? [String: Any])
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertFalse((source["data"] as? String ?? "").isEmpty)
    }

    func testHTTPFailurePreservesStatusAndProviderMessage() async {
        ProofGradingURLProtocol.respond(status: 429, object: ["error": ["message": "slow down"]])

        do {
            _ = try await ProofGradingService.buildRubric(
                question: "Q",
                modelAnswer: "A",
                apiKey: "test-key",
                session: makeSession()
            )
            XCTFail("Expected HTTP error")
        } catch let ProofGradingService.GradingError.http(status, message) {
            XCTAssertEqual(status, 429)
            XCTAssertEqual(message, "slow down")
        } catch {
            XCTFail("Expected HTTP error, got \(error)")
        }
    }

    func testMalformedSuccessfulResponseIsRejected() async {
        ProofGradingURLProtocol.respond(status: 200, object: [
            "content": [["type": "text", "text": "not-json"]]
        ])

        do {
            _ = try await ProofGradingService.buildRubric(
                question: "Q",
                modelAnswer: "A",
                apiKey: "test-key",
                session: makeSession()
            )
            XCTFail("Expected malformedResponse")
        } catch ProofGradingService.GradingError.malformedResponse {
            // Expected.
        } catch {
            XCTFail("Expected malformedResponse, got \(error)")
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProofGradingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func requestJSON() throws -> [String: Any] {
        let body = try XCTUnwrap(ProofGradingURLProtocol.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }
}

private final class ProofGradingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var status = 200
    private static var data = Data()
    private(set) static var request: URLRequest?
    private(set) static var body: Data?

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        status = 200
        data = Data()
        request = nil
        body = nil
    }

    static func respond(status: Int, object: Any) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        data = try! JSONSerialization.data(withJSONObject: object)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.request = request
        Self.body = request.httpBody ?? request.httpBodyStream.flatMap(Self.read)
        let responseStatus = Self.status
        let responseData = Self.data
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: responseStatus, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
