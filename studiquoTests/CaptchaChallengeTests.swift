import XCTest
@testable import studiquo

final class CaptchaChallengeTests: XCTestCase {
    // MARK: - Server response

    func testRequiredAndFailedBothAskForTheWidgetWithTheSiteKey() {
        for code in ["captcha_required", "captcha_failed"] {
            let data = Data(#"{"error":"x","code":"\#(code)","siteKey":"0x4AAAA"}"#.utf8)
            XCTAssertEqual(CaptchaServerResponse.parse(status: 403, data: data), .required(siteKey: "0x4AAAA"), code)
        }
    }

    func testUnavailableIsA503OnlyWithItsCode() {
        let data = Data(#"{"error":"x","code":"captcha_unavailable","siteKey":"k"}"#.utf8)
        XCTAssertEqual(CaptchaServerResponse.parse(status: 503, data: data), .unavailable)
        XCTAssertNil(CaptchaServerResponse.parse(status: 403, data: data))
    }

    func testOrdinaryFailuresAreNotCaptchaRefusals() {
        XCTAssertNil(CaptchaServerResponse.parse(status: 401, data: Data(#"{"error":"メールアドレスまたはパスワードが違います。"}"#.utf8)))
        XCTAssertNil(CaptchaServerResponse.parse(status: 403, data: Data(#"{"error":"forbidden"}"#.utf8)))
        XCTAssertNil(CaptchaServerResponse.parse(status: 403, data: Data()))
        XCTAssertNil(CaptchaServerResponse.parse(status: 403, data: Data("<html>".utf8)))
    }

    func testARefusalWithoutASiteKeyCannotShowAWidget() {
        XCTAssertNil(CaptchaServerResponse.parse(status: 403, data: Data(#"{"code":"captcha_required"}"#.utf8)))
        XCTAssertNil(CaptchaServerResponse.parse(status: 403, data: Data(#"{"code":"captcha_required","siteKey":""}"#.utf8)))
    }

    // MARK: - Challenge actions

    func testActionsMatchWhatTheServerVerifiesTheTokenFor() {
        XCTAssertEqual(CaptchaChallenge(siteKey: "k", continuation: .login(email: "a@b.c", password: "p")).action, "login")
        XCTAssertEqual(CaptchaChallenge(siteKey: "k", continuation: .beginAccountCreation(email: "a@b.c", password: "p")).action, "send-code")
        XCTAssertEqual(CaptchaChallenge(siteKey: "k", continuation: .resendCode).action, "send-code")
    }

    // MARK: - Widget page

    func testThePageCarriesTheSiteKeyAndActionAsStringLiterals() {
        let html = TurnstilePage.html(siteKey: "0x4AAAA-key", action: "login")
        XCTAssertTrue(html.contains(#"sitekey: "0x4AAAA-key""#))
        XCTAssertTrue(html.contains(#"action: "login""#))
        XCTAssertTrue(html.contains("https://challenges.cloudflare.com/turnstile/v0/api.js"))
    }

    func testAHostileSiteKeyCannotBreakOutOfItsStringOrTheScriptTag() {
        let html = TurnstilePage.html(siteKey: #"x"});alert(1);//</script><script>alert(2)</script>"#, action: "login")
        XCTAssertFalse(html.contains("</script><script>alert(2)"), "a closing script tag must not survive")
        XCTAssertFalse(html.contains(#"x"});alert(1)"#), "a double quote must stay escaped")
        XCTAssertEqual(html.components(separatedBy: "</script>").count - 1, 2, "only the page's own two script tags")
    }

    // MARK: - Widget messages

    func testATokenMessageIsAccepted() {
        XCTAssertEqual(TurnstileMessage(body: ["token": "abc.def"]), .token("abc.def"))
    }

    func testEmptyOrOversizedTokensAreIgnored() {
        XCTAssertNil(TurnstileMessage(body: ["token": ""]))
        XCTAssertNil(TurnstileMessage(body: ["token": String(repeating: "x", count: TurnstileMessage.maximumTokenLength + 1)]))
        XCTAssertEqual(
            TurnstileMessage(body: ["token": String(repeating: "x", count: TurnstileMessage.maximumTokenLength)]),
            .token(String(repeating: "x", count: TurnstileMessage.maximumTokenLength))
        )
    }

    func testErrorAndExpiredMessagesAreRecognised() {
        XCTAssertEqual(TurnstileMessage(body: ["error": "110200"]), .error)
        XCTAssertEqual(TurnstileMessage(body: ["expired": true]), .expired)
    }

    func testAnythingElseFromThePageIsIgnored() {
        XCTAssertNil(TurnstileMessage(body: "token"))
        XCTAssertNil(TurnstileMessage(body: ["token": 5]))
        XCTAssertNil(TurnstileMessage(body: ["expired": false]))
        XCTAssertNil(TurnstileMessage(body: [String: Any]()))
        XCTAssertNil(TurnstileMessage(body: ["other": "x"]))
    }
}
