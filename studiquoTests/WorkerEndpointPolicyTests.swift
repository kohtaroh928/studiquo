import XCTest
@testable import studiquo

final class WorkerEndpointPolicyTests: XCTestCase {
    func testReleasedBuildUsesTheProductionWorkerWhateverIsStored() {
        func resolved(_ stored: String?) -> String? { WorkerEndpointPolicy.resolve(stored, allowsCustomHosts: false)?.absoluteString }
        XCTAssertEqual(resolved(nil), "https://api.studiquo.app")
        XCTAssertEqual(resolved(""), "https://api.studiquo.app")
        XCTAssertEqual(resolved("  https://api.studiquo.app/ "), "https://api.studiquo.app")
        XCTAssertEqual(resolved("https://API.studiquo.app"), "https://API.studiquo.app", "the host is compared without regard to case")
        // Anywhere else is refused, so the token is never sent there.
        XCTAssertNil(resolved("https://attacker.example"))
        XCTAssertNil(resolved("https://studiquo-mcp-staging.studiquo-mcp-server.workers.dev"))
        XCTAssertNil(resolved("https://api.studiquo.app.attacker.example"))
        XCTAssertNil(resolved("https://attacker.example/api.studiquo.app"))
        XCTAssertNil(resolved("https://api.studiquo.app:8443"))
        XCTAssertNil(resolved("https://user:pass@api.studiquo.app"))
        XCTAssertNil(resolved("http://api.studiquo.app"))
    }

    func testTestingBuildMayUseStagingButStillOnlyOverHTTPS() {
        func resolved(_ stored: String?) -> URL? { WorkerEndpointPolicy.resolve(stored, allowsCustomHosts: true) }
        XCTAssertEqual(resolved("https://studiquo-mcp-staging.studiquo-mcp-server.workers.dev")?.host, "studiquo-mcp-staging.studiquo-mcp-server.workers.dev")
        XCTAssertNil(resolved("http://staging.example"))
        XCTAssertNil(resolved("https://user:pass@staging.example"))
        XCTAssertNil(resolved("not a url"))
    }

    func testTheBuiltInDefaultIsTheProductionHost() {
        XCTAssertEqual(URL(string: WorkerAIProvider.defaultEndpoint)?.host, WorkerEndpointPolicy.productionHost)
    }
}
