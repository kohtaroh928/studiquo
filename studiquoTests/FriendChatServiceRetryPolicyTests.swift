import XCTest
@testable import studiquo

final class FriendChatServiceRetryPolicyTests: XCTestCase {
    func testReadRequestRetriesATransientTransportFailure() {
        XCTAssertTrue(
            FriendChatService.shouldRetryReadRequest(
                method: "GET", error: URLError(.networkConnectionLost)
            )
        )
    }

    func testReadRequestRetriesAWorkerFailure() {
        XCTAssertTrue(FriendChatService.shouldRetryReadRequest(method: "GET", statusCode: 503))
    }

    func testMutationAndRateLimitAreNotRetried() {
        XCTAssertFalse(
            FriendChatService.shouldRetryReadRequest(
                method: "POST", error: URLError(.networkConnectionLost)
            )
        )
        XCTAssertFalse(FriendChatService.shouldRetryReadRequest(method: "GET", statusCode: 429))
    }
}
