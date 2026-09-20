import XCTest
@testable import studiquo

/// Coverage for `TextDocument.segments`, `replaceParagraphRun`, and
/// `insertTable(rows:columns:splitting:liveText:at:)` — the logic behind
/// showing a table inline between paragraphs instead of only ever below all
/// the text, and for keeping other segments' positions stable around edits
/// to one of them.
final class DocumentSegmentTests: XCTestCase {
    private func attributedString(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: DocumentBody.defaultAttributes())
    }

    private func paragraphBlocks(_ document: TextDocument, _ texts: [String]) -> [DocumentBlock] {
        texts.enumerated().map { index, text in
            let block = DocumentBlock(order: index, kind: .paragraph)
            block.bodyData = DocumentBody.encode(attributedString(text))
            block.document = document
            return block
        }
    }

    // MARK: segments

    func testAllParagraphBlocksFormOneTextSegment() {
        let document = TextDocument(title: "テスト")
        document.blocks = paragraphBlocks(document, ["段落A", "段落B", "段落C"])

        let segments = document.segments

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].kind, .text)
        XCTAssertEqual(segments[0].blocks.count, 3)
    }

    func testATableSplitsSurroundingParagraphsIntoSeparateSegments() {
        let document = TextDocument(title: "テスト")
        let before = paragraphBlocks(document, ["表の前"])
        let table = DocumentBlock.makeTable(order: 0, rows: 1, columns: 1)
        table.document = document
        let after = paragraphBlocks(document, ["表の後"])
        document.blocks = before + [table] + after

        let segments = document.segments

        XCTAssertEqual(segments.map(\.kind), [.text, .table, .text])
        XCTAssertEqual(segments[0].blocks.map { DocumentBody.decode($0.bodyData).string }, ["表の前"])
        XCTAssertEqual(segments[2].blocks.map { DocumentBody.decode($0.bodyData).string }, ["表の後"])
    }

    func testConsecutiveTablesEachGetTheirOwnSegment() {
        let document = TextDocument(title: "テスト")
        let table1 = DocumentBlock.makeTable(order: 0, rows: 1, columns: 1)
        table1.document = document
        let table2 = DocumentBlock.makeTable(order: 1, rows: 1, columns: 1)
        table2.document = document
        document.blocks = [table1, table2]

        XCTAssertEqual(document.segments.map(\.kind), [.table, .table])
    }

    // MARK: replaceParagraphRun

    func testReplaceParagraphRunKeepsATableAfterItInPlace() {
        let document = TextDocument(title: "テスト")
        let textRun = paragraphBlocks(document, ["元の段落"])
        let table = DocumentBlock.makeTable(order: 0, rows: 1, columns: 1)
        table.document = document
        document.blocks = textRun + [table]

        document.replaceParagraphRun(textRun, with: attributedString("新しい段落1\n新しい段落2"))

        let kinds = document.segments.map(\.kind)
        XCTAssertEqual(kinds, [.text, .table])
        XCTAssertEqual(document.segments[0].blocks.count, 2, "the run grew from 1 paragraph to 2")
    }

    func testReplaceParagraphRunKeepsATableBeforeItInPlace() {
        let document = TextDocument(title: "テスト")
        let table = DocumentBlock.makeTable(order: 0, rows: 1, columns: 1)
        table.document = document
        let textRun = paragraphBlocks(document, ["元の段落"])
        document.blocks = [table] + textRun

        document.replaceParagraphRun(textRun, with: attributedString("新しい段落"))

        XCTAssertEqual(document.segments.map(\.kind), [.table, .text])
        XCTAssertEqual(document.segments[1].blocks.map { DocumentBody.decode($0.bodyData).string }, ["新しい段落"])
    }

    // MARK: insertTable(splitting:)

    func testInsertTableSplitsTheSegmentAtTheCursor() {
        let document = TextDocument(title: "テスト")
        let liveText = attributedString("前半分後半分")
        let textRun = paragraphBlocks(document, [liveText.string])
        document.blocks = textRun
        let segment = document.segments[0]

        let result = document.insertTable(rows: 2, columns: 2, splitting: segment, liveText: liveText, at: 3)

        let segments = document.segments
        XCTAssertEqual(segments.map(\.kind), [.text, .table, .text])
        XCTAssertEqual(segments[0].blocks.map { DocumentBody.decode($0.bodyData).string }, ["前半分"])
        XCTAssertEqual(segments[2].blocks.map { DocumentBody.decode($0.bodyData).string }, ["後半分"])
        XCTAssertEqual(result.table.sortedTableRows.count, 2)
        XCTAssertEqual(result.table.tableColumnCount, 2)
    }

    func testInsertTableAtTheVeryStartLeavesAnEmptyLeadingSegment() {
        let document = TextDocument(title: "テスト")
        let liveText = attributedString("全部後ろに残る")
        let textRun = paragraphBlocks(document, [liveText.string])
        document.blocks = textRun
        let segment = document.segments[0]

        document.insertTable(rows: 1, columns: 1, splitting: segment, liveText: liveText, at: 0)

        let segments = document.segments
        XCTAssertEqual(segments.map(\.kind), [.text, .table, .text])
        XCTAssertEqual(segments[0].blocks.map { DocumentBody.decode($0.bodyData).string }, [""])
    }

    func testInsertTableAtTheVeryEndLeavesAnEmptyTrailingSegmentToKeepTypingIn() {
        let document = TextDocument(title: "テスト")
        let liveText = attributedString("全部前に残る")
        let textRun = paragraphBlocks(document, [liveText.string])
        document.blocks = textRun
        let segment = document.segments[0]

        let result = document.insertTable(rows: 1, columns: 1, splitting: segment, liveText: liveText, at: liveText.length)

        XCTAssertEqual(result.after.blocks.map { DocumentBody.decode($0.bodyData).string }, [""])
        XCTAssertEqual(document.segments.last?.kind, .text)
    }

    func testInsertTableIntoTheMiddleSegmentOfThreeLeavesTheOtherSegmentsAlone() {
        let document = TextDocument(title: "テスト")
        let firstTable = DocumentBlock.makeTable(order: 0, rows: 1, columns: 1)
        firstTable.document = document
        let liveText = attributedString("挿入対象")
        let middleRun = paragraphBlocks(document, [liveText.string])
        let secondTable = DocumentBlock.makeTable(order: 0, rows: 1, columns: 1)
        secondTable.document = document
        document.blocks = [firstTable] + middleRun + [secondTable]
        let middleSegment = document.segments[1]

        document.insertTable(rows: 1, columns: 1, splitting: middleSegment, liveText: liveText, at: 2)

        let kinds = document.segments.map(\.kind)
        XCTAssertEqual(kinds, [.table, .text, .table, .text, .table])
    }

    // MARK: insertEquation(splitting:)

    func testInsertEquationSplitsTheSegmentAtTheCursorAndStoresItsSource() {
        let document = TextDocument(title: "テスト")
        let liveText = attributedString("前半分後半分")
        let textRun = paragraphBlocks(document, [liveText.string])
        document.blocks = textRun
        let segment = document.segments[0]

        let result = document.insertEquation(source: "x^2", splitting: segment, liveText: liveText, at: 3)

        let segments = document.segments
        XCTAssertEqual(segments.map(\.kind), [.text, .equation, .text])
        XCTAssertEqual(result.equation.equationSource, "x^2")
        XCTAssertEqual(result.equation.kind, .equation)
    }

    func testAnEquationBetweenTwoTablesGetsItsOwnSegment() {
        let document = TextDocument(title: "テスト")
        let table = DocumentBlock.makeTable(order: 0, rows: 1, columns: 1)
        table.document = document
        let equation = DocumentBlock(order: 1, kind: .equation)
        equation.equationSource = "\\pi"
        equation.document = document
        document.blocks = [table, equation]

        XCTAssertEqual(document.segments.map(\.kind), [.table, .equation])
    }
}

/// Coverage for `TextDocument.listMarker(for:)` (auto-renumbering) and
/// `DocumentBlockText.carryOverListMetadata` (list state surviving the
/// block-recreation every commit does).
final class DocumentListTests: XCTestCase {
    private func listBlocks(_ document: TextDocument, kind: DocumentListKind, count: Int, level: Int = 0) -> [DocumentBlock] {
        (0..<count).map { index in
            let block = DocumentBlock(order: index, kind: .paragraph)
            block.listKind = kind
            block.listLevel = level
            block.document = document
            return block
        }
    }

    /// `listMarker` walks `sortedBlocks`, which sorts by `.order` — so every
    /// fixture combining several `listBlocks()`/`makeTable()` groups (each
    /// numbered from 0 on its own) needs its blocks renumbered to their
    /// actual combined position, or the sort scrambles the intended order.
    private func renumber(_ document: TextDocument) {
        for (index, block) in (document.blocks ?? []).enumerated() { block.order = index }
    }

    func testPlainParagraphHasNoMarker() {
        let document = TextDocument(title: "テスト")
        let block = DocumentBlock(order: 0, kind: .paragraph)
        block.document = document
        document.blocks = [block]

        XCTAssertNil(document.listMarker(for: block))
    }

    func testBulletedListUsesTheSameGlyphForEveryItem() {
        let document = TextDocument(title: "テスト")
        let items = listBlocks(document, kind: .bulleted, count: 3)
        document.blocks = items

        XCTAssertEqual(items.map { document.listMarker(for: $0) }, ["•", "•", "•"])
    }

    func testNumberedListAutoIncrements() {
        let document = TextDocument(title: "テスト")
        let items = listBlocks(document, kind: .numbered, count: 3)
        document.blocks = items

        XCTAssertEqual(items.map { document.listMarker(for: $0) }, ["1.", "2.", "3."])
    }

    func testNumberingRestartsAfterANonListParagraph() {
        let document = TextDocument(title: "テスト")
        let firstList = listBlocks(document, kind: .numbered, count: 2)
        let plain = DocumentBlock(order: 0, kind: .paragraph)
        plain.document = document
        let secondList = listBlocks(document, kind: .numbered, count: 2)
        document.blocks = firstList + [plain] + secondList
        renumber(document)

        XCTAssertEqual(secondList.map { document.listMarker(for: $0) }, ["1.", "2."], "a plain paragraph breaks the run, restarting the count")
    }

    func testNumberingRestartsAcrossATable() {
        let document = TextDocument(title: "テスト")
        let firstList = listBlocks(document, kind: .numbered, count: 2)
        let table = DocumentBlock.makeTable(order: 0, rows: 1, columns: 1)
        table.document = document
        let secondList = listBlocks(document, kind: .numbered, count: 2)
        document.blocks = firstList + [table] + secondList
        renumber(document)

        XCTAssertEqual(secondList.map { document.listMarker(for: $0) }, ["1.", "2."])
    }

    func testMixingBulletedAndNumberedAtTheSamePositionRestartsEach() {
        let document = TextDocument(title: "テスト")
        let numbered = listBlocks(document, kind: .numbered, count: 2)
        let bulleted = listBlocks(document, kind: .bulleted, count: 2)
        document.blocks = numbered + bulleted
        renumber(document)

        XCTAssertEqual(bulleted.map { document.listMarker(for: $0) }, ["•", "•"])
    }

    func testNestedNumberedLevelsUseLetterAndRomanStyles() {
        let document = TextDocument(title: "テスト")
        let level0 = listBlocks(document, kind: .numbered, count: 1, level: 0)
        let level1 = listBlocks(document, kind: .numbered, count: 3, level: 1)
        let level2 = listBlocks(document, kind: .numbered, count: 3, level: 2)
        document.blocks = level0 + level1 + level2
        renumber(document)

        XCTAssertEqual(level0.map { document.listMarker(for: $0) }, ["1."])
        XCTAssertEqual(level1.map { document.listMarker(for: $0) }, ["a.", "b.", "c."])
        XCTAssertEqual(level2.map { document.listMarker(for: $0) }, ["i.", "ii.", "iii."])
    }

    // MARK: carryOverListMetadata

    func testCarryOverPreservesListStateIndexForIndex() {
        let document = TextDocument(title: "テスト")
        let old = listBlocks(document, kind: .numbered, count: 2)
        let fresh = [DocumentBlock(order: 0, kind: .paragraph), DocumentBlock(order: 1, kind: .paragraph)]

        DocumentBlockText.carryOverListMetadata(from: old, to: fresh)

        XCTAssertEqual(fresh.map(\.listKind), [.numbered, .numbered])
    }

    func testCarryOverForANewParagraphInheritsThePreviousNewParagraphsState() {
        // Simulates pressing return inside a list item: the old run had 1
        // paragraph, the new run (after the edit) has 2.
        let document = TextDocument(title: "テスト")
        let old = listBlocks(document, kind: .bulleted, count: 1)
        let fresh = [DocumentBlock(order: 0, kind: .paragraph), DocumentBlock(order: 1, kind: .paragraph)]

        DocumentBlockText.carryOverListMetadata(from: old, to: fresh)

        XCTAssertEqual(fresh.map(\.listKind), [.bulleted, .bulleted], "the new second paragraph should continue the list")
    }

    func testCarryOverToFewerParagraphsDropsTheExtraOldState() {
        let document = TextDocument(title: "テスト")
        let old = listBlocks(document, kind: .numbered, count: 3)
        let fresh = [DocumentBlock(order: 0, kind: .paragraph)]

        DocumentBlockText.carryOverListMetadata(from: old, to: fresh)

        XCTAssertEqual(fresh[0].listKind, .numbered)
    }

    func testCarryOverPreservesParagraphStyleIndexForIndex() {
        let old = DocumentBlock(order: 0, kind: .paragraph)
        old.paragraphStyle = .heading1
        let fresh = [DocumentBlock(order: 0, kind: .paragraph)]

        DocumentBlockText.carryOverListMetadata(from: [old], to: fresh)

        XCTAssertEqual(fresh[0].paragraphStyle, .heading1)
    }

    /// The regression this guards: a heading you just typed a return after
    /// must not turn the brand new line into a heading too.
    func testCarryOverDoesNotPropagateParagraphStyleToANewParagraph() {
        let old = DocumentBlock(order: 0, kind: .paragraph)
        old.paragraphStyle = .heading1
        let fresh = [DocumentBlock(order: 0, kind: .paragraph), DocumentBlock(order: 1, kind: .paragraph)]

        DocumentBlockText.carryOverListMetadata(from: [old], to: fresh)

        XCTAssertNil(fresh[1].paragraphStyle)
    }
}

/// Coverage for `TextDocument.tableOfContentsLines` and the footnote
/// numbering/ordering helpers (`sortedFootnotes`/`footnoteNumber(for:)`).
final class DocumentTableOfContentsAndFootnoteTests: XCTestCase {
    private func paragraph(_ document: TextDocument, order: Int, text: String, style: DocumentParagraphStyle?) -> DocumentBlock {
        let block = DocumentBlock(order: order, kind: .paragraph)
        block.bodyData = DocumentBody.encode(NSAttributedString(string: text, attributes: DocumentBody.defaultAttributes()))
        block.paragraphStyle = style
        block.document = document
        return block
    }

    func testTableOfContentsListsOnlyHeadingsInOrderWithLevels() {
        let document = TextDocument(title: "テスト")
        let title = paragraph(document, order: 0, text: "文書タイトル", style: .title)
        let body1 = paragraph(document, order: 1, text: "普通の本文", style: nil)
        let h1 = paragraph(document, order: 2, text: "第1章", style: .heading1)
        let h2 = paragraph(document, order: 3, text: "1.1節", style: .heading2)
        let quote = paragraph(document, order: 4, text: "引用文", style: .quote)
        document.blocks = [title, body1, h1, h2, quote]

        let lines = document.tableOfContentsLines

        XCTAssertEqual(lines.map(\.text), ["文書タイトル", "第1章", "1.1節"])
        XCTAssertEqual(lines.map(\.level), [0, 1, 2])
    }

    func testTableOfContentsSkipsEmptyHeadings() {
        let document = TextDocument(title: "テスト")
        let empty = paragraph(document, order: 0, text: "   ", style: .heading1)
        document.blocks = [empty]

        XCTAssertTrue(document.tableOfContentsLines.isEmpty)
    }

    func testTableOfContentsIsEmptyWithNoHeadings() {
        let document = TextDocument(title: "テスト")
        document.blocks = [paragraph(document, order: 0, text: "本文のみ", style: nil)]

        XCTAssertTrue(document.tableOfContentsLines.isEmpty)
    }

    func testFootnotesAreOrderedByTheirAnchorBlocksPosition() {
        let document = TextDocument(title: "テスト")
        let first = DocumentBlock(order: 0, kind: .paragraph)
        first.document = document
        let second = DocumentBlock(order: 1, kind: .paragraph)
        second.document = document
        document.blocks = [first, second]

        // Added out of document order — the second paragraph's footnote
        // first — to make sure ordering comes from position, not insertion.
        let noteOnSecond = second.addFootnote(text: "後ろの段落の注")
        let noteOnFirst = first.addFootnote(text: "最初の段落の注")

        XCTAssertEqual(document.sortedFootnotes.map(\.text), ["最初の段落の注", "後ろの段落の注"])
        XCTAssertEqual(document.footnoteNumber(for: noteOnFirst), 1)
        XCTAssertEqual(document.footnoteNumber(for: noteOnSecond), 2)
    }

    func testFootnoteNumbersRenumberWhenAnEarlierOneIsRemoved() {
        let document = TextDocument(title: "テスト")
        let block = DocumentBlock(order: 0, kind: .paragraph)
        block.document = document
        document.blocks = [block]
        let first = block.addFootnote(text: "1つ目")
        let second = block.addFootnote(text: "2つ目")

        block.anchoredFootnotes?.removeAll { $0 === first }

        XCTAssertEqual(document.footnoteNumber(for: second), 1, "renumbers down once the earlier footnote is gone")
    }
}

/// Coverage for `TextDocument.searchMatches`/`replaceMatch`/
/// `replaceAllMatches`.
final class DocumentSearchTests: XCTestCase {
    private func paragraph(_ document: TextDocument, order: Int, text: String) -> DocumentBlock {
        let block = DocumentBlock(order: order, kind: .paragraph)
        block.bodyData = DocumentBody.encode(NSAttributedString(string: text, attributes: DocumentBody.defaultAttributes()))
        block.document = document
        return block
    }

    func testFindsMatchesAcrossMultipleBlocksInOrder() {
        let document = TextDocument(title: "テスト")
        let first = paragraph(document, order: 0, text: "りんごを買う")
        let second = paragraph(document, order: 1, text: "みかんを買う")
        document.blocks = [first, second]

        let matches = document.searchMatches(for: "買う")

        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(matches[0].block === first)
        XCTAssertTrue(matches[1].block === second)
    }

    func testFindsMultipleMatchesWithinTheSameBlock() {
        let document = TextDocument(title: "テスト")
        let block = paragraph(document, order: 0, text: "猫と犬と猫")
        document.blocks = [block]

        let matches = document.searchMatches(for: "猫")

        XCTAssertEqual(matches.map(\.range.location), [0, 4])
    }

    func testSearchIsCaseInsensitive() {
        let document = TextDocument(title: "テスト")
        document.blocks = [paragraph(document, order: 0, text: "Hello World")]

        XCTAssertEqual(document.searchMatches(for: "world").count, 1)
    }

    func testEmptyQueryFindsNothing() {
        let document = TextDocument(title: "テスト")
        document.blocks = [paragraph(document, order: 0, text: "何か本文")]

        XCTAssertTrue(document.searchMatches(for: "").isEmpty)
    }

    func testSearchSkipsNonParagraphBlocks() {
        let document = TextDocument(title: "テスト")
        let table = DocumentBlock.makeTable(order: 0, rows: 1, columns: 1)
        table.document = document
        table.sortedTableRows[0].sortedCells[0].text = "見つける"
        document.blocks = [table]

        XCTAssertTrue(document.searchMatches(for: "見つける").isEmpty, "table cell text is out of scope for v1 search")
    }

    func testReplaceMatchUpdatesOnlyThatBlock() {
        let document = TextDocument(title: "テスト")
        let block = paragraph(document, order: 0, text: "赤いりんご")
        document.blocks = [block]
        let match = document.searchMatches(for: "赤い")[0]

        document.replaceMatch(match, with: "青い")

        XCTAssertEqual(DocumentBody.decode(block.bodyData).string, "青いりんご")
    }

    func testReplaceAllMatchesHandlesMultipleHitsInTheSameBlockWithoutCorruptingLaterOnes() {
        // The regression this guards: replacing "猫"→"犬" at location 0
        // first would shift the second match's stored location (4) if
        // replacements weren't applied last-location-first.
        let document = TextDocument(title: "テスト")
        let block = paragraph(document, order: 0, text: "猫と犬と猫")
        document.blocks = [block]
        let matches = document.searchMatches(for: "猫")

        document.replaceAllMatches(matches, with: "鳥")

        XCTAssertEqual(DocumentBody.decode(block.bodyData).string, "鳥と犬と鳥")
    }

    func testReplaceAllMatchesAcrossMultipleBlocks() {
        let document = TextDocument(title: "テスト")
        let first = paragraph(document, order: 0, text: "赤いりんご")
        let second = paragraph(document, order: 1, text: "赤い自転車")
        document.blocks = [first, second]
        let matches = document.searchMatches(for: "赤い")

        document.replaceAllMatches(matches, with: "青い")

        XCTAssertEqual(DocumentBody.decode(first.bodyData).string, "青いりんご")
        XCTAssertEqual(DocumentBody.decode(second.bodyData).string, "青い自転車")
    }

    func testReplacementWithADifferentLengthDoesNotCorruptSubsequentMatchesInTheSameBlock() {
        // "猫" (1 char) → "子猫ちゃん" (5 chars): a length-changing
        // replacement, still applied last-location-first.
        let document = TextDocument(title: "テスト")
        let block = paragraph(document, order: 0, text: "猫と犬と猫")
        document.blocks = [block]
        let matches = document.searchMatches(for: "猫")

        document.replaceAllMatches(matches, with: "子猫ちゃん")

        XCTAssertEqual(DocumentBody.decode(block.bodyData).string, "子猫ちゃんと犬と子猫ちゃん")
    }
}
