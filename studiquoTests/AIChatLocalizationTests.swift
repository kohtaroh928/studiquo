import XCTest
@testable import studiquo

/// The English wording of the strings added for the AI home tab and the
/// missed-card reminders, including the interpolated ones whose argument
/// order differs between languages.
final class AIChatLocalizationTests: XCTestCase {
    private func englishBundle() throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"), "en.lproj が見つかりません")
        return try XCTUnwrap(Bundle(path: path))
    }

    func testAIChatScreenStringsHaveEnglishText() throws {
        let en = try englishBundle()
        XCTAssertEqual(String(localized: "何を手伝いましょうか？", bundle: en), "How can I help?")
        XCTAssertEqual(String(localized: "ページに貼り付け", bundle: en), "Paste onto Page")
        XCTAssertEqual(String(localized: "生成を止める", bundle: en), "Stop Generating")
        XCTAssertEqual(String(localized: "新しいトーク", bundle: en), "New Chat")
        XCTAssertEqual(String(localized: "コピー", bundle: en), "Copy")
    }

    func testAnswerReadyNotificationHasEnglishText() throws {
        let en = try englishBundle()
        XCTAssertEqual(String(localized: "AIの回答が完成しました", bundle: en), "Your AI answer is ready")
    }

    func testMissedCardReminderTextsHaveEnglishTextWithTheirArguments() throws {
        let en = try englishBundle()
        XCTAssertEqual(String(localized: "間違えた問題が\(3)問あります", bundle: en), "You have 3 missed cards to review")
        XCTAssertEqual(String(localized: "今日の復習対象が\(5)枚あります", bundle: en), "5 cards are due for review today")
        // The title comes first in Japanese but the count first in English.
        XCTAssertEqual(
            String(localized: "『\("英単語")』の\(2)問を復習しましょう。Q. \("apple")", bundle: en),
            "Time to review the 2 missed card(s) in “英単語”. Q. apple"
        )
    }

    func testJapaneseStaysTheSourceLanguage() {
        XCTAssertEqual(String(localized: "間違えた問題が\(3)問あります"), "間違えた問題が3問あります")
    }
}
