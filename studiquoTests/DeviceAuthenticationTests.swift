import XCTest
@testable import studiquo

final class DeviceAuthenticationTests: XCTestCase {
    private enum TestError: Error { case failed }

    func testUnavailableAuthenticationReturnsFalseWithoutEvaluation() async {
        let result = await DeviceAuthentication.authenticate(
            reason: "保護を解除します",
            canEvaluate: { false },
            evaluate: { _ in
                XCTFail("利用できない端末では認証を開始してはいけません")
                return true
            }
        )

        XCTAssertFalse(result)
    }

    func testSuccessfulEvaluationReturnsTrueAndForwardsReason() async {
        let result = await DeviceAuthentication.authenticate(
            reason: "「数学ノート」を開きます",
            canEvaluate: { true },
            evaluate: { reason in
                XCTAssertEqual(reason, "「数学ノート」を開きます")
                return true
            }
        )

        XCTAssertTrue(result)
    }

    func testRejectedEvaluationReturnsFalse() async {
        let result = await DeviceAuthentication.authenticate(
            reason: "認証してください",
            canEvaluate: { true },
            evaluate: { _ in false }
        )

        XCTAssertFalse(result)
    }

    func testEvaluationErrorReturnsFalse() async {
        let result = await DeviceAuthentication.authenticate(
            reason: "認証してください",
            canEvaluate: { true },
            evaluate: { _ in throw TestError.failed }
        )

        XCTAssertFalse(result)
    }
}
