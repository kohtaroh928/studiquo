import XCTest
@testable import studiquo

final class DocumentCollabInviteTests: XCTestCase {
    func testPendingInviteListIsDecodedWithTheRoomAsItsIdentity() throws {
        let json = #"[{"roomID":"aaaa","role":"editor","inviterName":"田中","createdAt":1700000000000},{"roomID":"bbbb","role":"reviewer","inviterName":null,"createdAt":1700000001000}]"#
        let invites = try JSONDecoder().decode([DocumentCollabService.PendingInvite].self, from: Data(json.utf8))
        XCTAssertEqual(invites.map(\.id), ["aaaa", "bbbb"])
        XCTAssertEqual(invites[0].inviterName, "田中")
        XCTAssertNil(invites[1].inviterName)
        XCTAssertEqual(invites[1].role, "reviewer")
    }

    func testInviteAnswerCarriesTheStatusTheServerSends() throws {
        let joined = try JSONDecoder().decode(DocumentCollabService.InviteAnswer.self, from: Data(#"{"status":"joined","role":"editor"}"#.utf8))
        XCTAssertEqual(joined.status, "joined")
        XCTAssertEqual(joined.role, "editor")
        let declined = try JSONDecoder().decode(DocumentCollabService.InviteAnswer.self, from: Data(#"{"status":"declined"}"#.utf8))
        XCTAssertEqual(declined.status, "declined")
        XCTAssertNil(declined.role)
    }
}
