import XCTest
@testable import studiquo

final class MCPConnectionKindTests: XCTestCase {
    func testKindsMatchWhatTheServerAccepts() {
        XCTAssertEqual(MCPConnectionKind.allCases.map(\.rawValue), ["claude", "chatgpt", "codex", "other"])
    }

    func testPairingCodeAnswerIsDecodedAndGroupedForReading() throws {
        let json = #"{"code":"ABCDEFGHJKMN","kind":"chatgpt","expiresInSeconds":300}"#
        let issued = try JSONDecoder().decode(MCPPairingCode.self, from: Data(json.utf8))
        XCTAssertEqual(issued.kind, .chatgpt)
        XCTAssertEqual(issued.expiresInSeconds, 300)
        XCTAssertEqual(issued.groupedCode, "ABCD-EFGH-JKMN")
    }

    func testUnknownKindFromTheServerIsRejectedRatherThanGuessed() {
        let json = #"{"code":"ABCDEFGHJKMN","kind":"mystery","expiresInSeconds":300}"#
        XCTAssertThrowsError(try JSONDecoder().decode(MCPPairingCode.self, from: Data(json.utf8)))
    }
}
