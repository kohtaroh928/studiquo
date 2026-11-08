import XCTest
@testable import studiquo

final class PasskeyResetHoldTests: XCTestCase {
    private func body(_ code: String) -> Data { Data(#"{"error":"x","code":"\#(code)","availableAt":1}"#.utf8) }

    func testOnlyA403WithTheHoldCodeIsTheHold() {
        XCTAssertTrue(PasskeyResetHold.isActive(status: 403, body: body("passkey_reset_hold")))
        XCTAssertFalse(PasskeyResetHold.isActive(status: 403, body: body("email_code_required")))
        XCTAssertFalse(PasskeyResetHold.isActive(status: 403, body: body("reauth_required")))
        XCTAssertFalse(PasskeyResetHold.isActive(status: 500, body: body("passkey_reset_hold")))
        XCTAssertFalse(PasskeyResetHold.isActive(status: 403, body: Data("not json".utf8)))
        XCTAssertFalse(PasskeyResetHold.isActive(status: nil, body: Data()))
    }

    func testTheMessageSaysToWaitAndNotThatTheServerFailed() {
        let message = PasskeyError.resetHold.errorDescription ?? ""
        XCTAssertTrue(message.contains("48時間"))
        XCTAssertNotEqual(message, PasskeyError.serverRejected.errorDescription)
    }
}
