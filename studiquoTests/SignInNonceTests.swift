import AuthenticationServices
import XCTest
@testable import studiquo

final class SignInNonceTests: XCTestCase {
    func testTheRawNonceIs64HexCharactersAndTheHashIsItsSHA256() {
        let nonce = SignInNonce.make()
        XCTAssertEqual(nonce.raw.count, 64)
        XCTAssertNotNil(nonce.raw.wholeMatch(of: /[0-9a-f]{64}/))
        XCTAssertEqual(nonce.hashed.count, 64)
        XCTAssertNotNil(nonce.hashed.wholeMatch(of: /[0-9a-f]{64}/))
        XCTAssertEqual(nonce.hashed, SignInNonce.sha256Hex(nonce.raw))
        XCTAssertNotEqual(nonce.raw, nonce.hashed)
    }

    func testSHA256MatchesTheKnownTestVector() {
        XCTAssertEqual(SignInNonce.sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testEveryNonceIsDifferent() {
        let raws = Set((0..<100).map { _ in SignInNonce.make().raw })
        XCTAssertEqual(raws.count, 100)
    }

    /// What the server accepts: the raw nonce matches /^[A-Za-z0-9_-]{16,200}$/.
    func testTheRawNonceIsInTheShapeTheServerAccepts() {
        XCTAssertNotNil(SignInNonce.make().raw.wholeMatch(of: /[A-Za-z0-9_-]{16,200}/))
    }

    func testThePendingNonceIsTakenOnceAndThenForgotten() {
        let pending = PendingSignInNonce()
        XCTAssertNil(pending.take())
        let nonce = SignInNonce.make()
        pending.store(nonce)
        XCTAssertEqual(pending.take(), nonce)
        XCTAssertNil(pending.take(), "one sign-in, one nonce")
    }

    func testANewerNonceReplacesAnOlderOneThatWasNeverUsed() {
        let pending = PendingSignInNonce()
        let first = SignInNonce.make()
        let second = SignInNonce.make()
        pending.store(first)
        pending.store(second)
        XCTAssertEqual(pending.take(), second)
    }

    func testPreparingAnAppleRequestSetsTheScopesAndAHashedNonce() {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        AppleSignInService.prepare(request)
        XCTAssertEqual(request.requestedScopes, [.email])
        XCTAssertNotNil(request.nonce?.wholeMatch(of: /[0-9a-f]{64}/))
        let other = ASAuthorizationAppleIDProvider().createRequest()
        AppleSignInService.prepare(other)
        XCTAssertNotEqual(request.nonce, other.nonce, "each request gets its own nonce")
    }
}
