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
        XCTAssertEqual(resolved("https://staging-api.studiquo.app")?.host, "staging-api.studiquo.app")
        XCTAssertNil(resolved("https://attacker.example"))
        XCTAssertNil(resolved("https://studiquo-mcp-staging.studiquo-mcp-server.workers.dev/path"))
        XCTAssertNil(resolved("https://studiquo-mcp-staging.studiquo-mcp-server.workers.dev?query"))
        XCTAssertNil(resolved("http://staging.example"))
        XCTAssertNil(resolved("https://user:pass@staging.example"))
        XCTAssertNil(resolved("not a url"))
    }

    func testTheBuiltInDefaultIsTheProductionHost() {
        XCTAssertEqual(URL(string: WorkerAIProvider.defaultEndpoint)?.host, WorkerEndpointPolicy.productionHost)
    }
    func testLaunchStoreClassificationAndRAGEndpointLock() {
        let production = URL(string: "https://api.studiquo.app")!
        let staging = URL(string: "https://studiquo-mcp-staging.studiquo-mcp-server.workers.dev")!
        XCTAssertTrue(LaunchStoreEnvironment.isProduction(production))
        XCTAssertFalse(LaunchStoreEnvironment.isProduction(staging))
        XCTAssertTrue(LaunchStoreEnvironment.isStaging(staging))
        XCTAssertFalse(LaunchStoreEnvironment.isStaging(URL(string: "https://another.example")!))
        XCTAssertFalse(LaunchStoreEnvironment.isStaging(URL(string: "https://studiquo-mcp-staging.studiquo-mcp-server.workers.dev:444")!))
        XCTAssertFalse(LaunchStoreEnvironment.isStaging(URL(string: "https://studiquo-mcp-staging.studiquo-mcp-server.workers.dev/other")!))
        XCTAssertTrue(LaunchStoreEnvironment.isStaging(URL(string: "https://staging-api.studiquo.app")!))
        let lock = EndpointChangeLock(launch: staging)
        XCTAssertTrue(lock.allows(staging))
        XCTAssertFalse(lock.allows(production))
        XCTAssertFalse(lock.allows(staging), "A restart is still required after reverting the setting")
        XCTAssertFalse(EndpointChangeLock(launch: production).allows(staging))
        XCTAssertFalse(EndpointChangeLock(launch: production).allows(nil))
        XCTAssertFalse(EndpointChangeLock(launch: nil).allows(production))
    }

}
