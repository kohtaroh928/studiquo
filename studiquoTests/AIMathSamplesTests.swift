import XCTest
@testable import studiquo

/// Keeps the shared AI-output corpus honest: if a sample is mislabelled or
/// malformed, every test built on it would quietly check the wrong thing.
final class AIMathSamplesTests: XCTestCase {
    private let all = AIMathSamples.all

    func testTheCorpusIsLargeAndCoversEveryCategory() {
        XCTAssertGreaterThanOrEqual(all.count, 100)
        for category in AIMathSample.Category.allCases {
            let count = all.filter { $0.category == category }.count
            XCTAssertGreaterThanOrEqual(count, 3, "\(category.rawValue) のサンプルが少なすぎます")
        }
    }

    func testIdsAreUniqueAndLookupWorks() {
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "idが重複しています")
        XCTAssertEqual(AIMathSamples.sample(id: "quadratic-formula")?.category, .algebra)
        XCTAssertNil(AIMathSamples.sample(id: "no-such-sample"))
    }

    func testSamplesAreNotEmptyAndNotHuge() {
        for sample in all {
            XCTAssertFalse(sample.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(sample) が空です")
            XCTAssertLessThan(sample.text.count, 3000, "\(sample) が長すぎます")
        }
    }

    func testMathFlagsMatchTheirText() {
        for sample in all {
            let text = sample.text
            if sample.hasInlineMath {
                XCTAssertTrue(text.contains("$") || text.contains("\\("), "\(sample): hasInlineMath なのに式がありません")
            }
            if sample.hasDisplayMath {
                XCTAssertTrue(
                    text.contains("$$") || text.contains("\\[") || text.contains("\\begin"),
                    "\(sample): hasDisplayMath なのに独立した式がありません"
                )
            }
        }
    }

    func testOnlyStreamingSamplesAreMarkedPartial() {
        for sample in all {
            XCTAssertEqual(
                sample.isPartial, sample.category == .streamingPrefix,
                "\(sample): isPartial の指定が categoryと合っていません"
            )
        }
    }

    /// A well-formed sample has paired `$` delimiters once code and escaped
    /// dollars are ignored. Prices, shell variables and cut-off samples are
    /// unbalanced on purpose.
    func testMathSamplesHavePairedDollarSigns() {
        let exempt: Set<AIMathSample.Category> = [.falsePositive, .streamingPrefix]
        for sample in all where !exempt.contains(sample.category) {
            var text = sample.text
            text = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "`[^`]*`", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\$", with: "")
            let dollars = text.filter { $0 == "$" }.count
            XCTAssertEqual(dollars % 2, 0, "\(sample): $ の数が奇数です")
        }
    }

    func testStreamingPrefixesGrowAndEndWithTheFullText() throws {
        let text = try XCTUnwrap(AIMathSamples.sample(id: "reply-derivative-plan")).text
        for step in [1, 7, 50] {
            let prefixes = AIMathSamples.streamingPrefixes(of: text, step: step)
            XCTAssertEqual(prefixes.last, text)
            var previous = 0
            for prefix in prefixes {
                XCTAssertTrue(text.hasPrefix(prefix))
                XCTAssertGreaterThan(prefix.count, previous, "接頭辞は少しずつ長くなる")
                previous = prefix.count
            }
        }
        XCTAssertTrue(AIMathSamples.streamingPrefixes(of: "").isEmpty)
    }
}
