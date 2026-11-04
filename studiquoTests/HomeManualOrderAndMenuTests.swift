import SwiftData
import XCTest
@testable import studiquo

@MainActor
final class HomeManualOrderAndMenuTests: XCTestCase {
    private static var retainedContainers: [ModelContainer] = []

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: studiquoSchema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: studiquoSchema, configurations: configuration)
        Self.retainedContainers.append(container)
        return container
    }

    private func contentViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // studiquoTests/
            .deletingLastPathComponent()  // project root
            .appendingPathComponent("studiquo/Views/ContentView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func projectYmlSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sliceFunction(_ signature: String, until nextMarker: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), "関数が見つかりません: \(signature)")
        let rest = source[start.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: nextMarker), "終端マーカーが見つかりません: \(nextMarker)")
        return String(rest[..<end.lowerBound])
    }

    // MARK: - 1. ホーム資料の手動並べ替え (sortIndex / HomeEntry / ContentView)

    func testAllHomeItemModelsDefaultToZeroSortIndexAndForwardThroughHomeEntry() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let notebook = Notebook(title: "ノートA")
        let deck = FlashcardDeck(title: "単語帳A")
        let document = TextDocument(title: "文書A")
        context.insert(notebook)
        context.insert(deck)
        context.insert(document)

        XCTAssertEqual(notebook.sortIndex, 0, "Notebook の sortIndex 初期値は 0 である必要があります。")
        XCTAssertEqual(deck.sortIndex, 0, "FlashcardDeck の sortIndex 初期値は 0 である必要があります。")
        XCTAssertEqual(document.sortIndex, 0, "TextDocument の sortIndex 初期値は 0 である必要があります。")

        var notebookEntry = HomeEntry.notebook(notebook)
        var deckEntry = HomeEntry.flashcardDeck(deck)
        var documentEntry = HomeEntry.textDocument(document)

        notebookEntry.sortIndex = 3
        deckEntry.sortIndex = 1
        documentEntry.sortIndex = 2

        XCTAssertEqual(notebook.sortIndex, 3, "HomeEntry.sortIndex への代入は Notebook.sortIndex に反映される必要があります。")
        XCTAssertEqual(deck.sortIndex, 1, "HomeEntry.sortIndex への代入は FlashcardDeck.sortIndex に反映される必要があります。")
        XCTAssertEqual(document.sortIndex, 2, "HomeEntry.sortIndex への代入は TextDocument.sortIndex に反映される必要があります。")

        try context.save()
        let readContext = ModelContext(container)
        XCTAssertEqual(try XCTUnwrap(readContext.fetch(FetchDescriptor<Notebook>()).first).sortIndex, 3)
        XCTAssertEqual(try XCTUnwrap(readContext.fetch(FetchDescriptor<FlashcardDeck>()).first).sortIndex, 1)
        XCTAssertEqual(try XCTUnwrap(readContext.fetch(FetchDescriptor<TextDocument>()).first).sortIndex, 2)
    }

    func testManualEntryOrderAndLibraryRowManualSortImplementation() throws {
        let source = try contentViewSource()

        // manualEntryOrder: sortOption == .manual のとき sortIndex 昇順、同値なら updatedNewest にフォールバック
        let manualOrderSlice = try sliceFunction(
            "private func manualEntryOrder(_ first: HomeEntry, _ second: HomeEntry) -> Bool",
            until: "@ViewBuilder",
            in: source
        )
        XCTAssertTrue(
            manualOrderSlice.contains("guard sortOption == .manual else { return sortOption.areInOrder(first, second) }")
                && manualOrderSlice.contains("if first.sortIndex != second.sortIndex { return first.sortIndex < second.sortIndex }")
                && manualOrderSlice.contains("return NotebookSortOption.updatedNewest.areInOrder(first, second)"),
            "manualEntryOrder は手動ソート時に sortIndex 昇順で並べ、同値(初期値0同士など)のときは updatedNewest にフォールバックする必要があります。"
        )

        // LibraryRowItem の混在ソートでも Folder.sortIndex と HomeEntry.sortIndex を比較すること
        let rowSortSlice = try sliceFunction(
            "let items = folders.map(LibraryRowItem.folder) + entries.map(LibraryRowItem.entry)",
            until: "if sortByMaterialType {",
            in: source
        )
        XCTAssertTrue(
            rowSortSlice.contains("if sortOption == .manual")
                && rowSortSlice.contains("case .folder(let path): return folderObject(forLegacyPath: path)?.sortIndex ?? 0")
                && rowSortSlice.contains("case .entry(let entry): return entry.sortIndex")
                && rowSortSlice.contains("if firstIndex != secondIndex { return firstIndex < secondIndex }"),
            "一覧の LibraryRowItem ソートは手動モード時にフォルダと資料の sortIndex を比較する必要があります。"
        )
    }

    func testManualModeEntryDropReordersInsteadOfCreatingFolderAndFolderDropAppendsIndex() throws {
        let source = try contentViewSource()

        // 1. handleEntryDrop: 手動モード時はフォルダ新規作成ではなく reorder(source, after: target) を呼ぶこと
        let entryDropSlice = try sliceFunction(
            "private func handleEntryDrop(_ values: [String], onto target: HomeEntry) -> Bool",
            until: "@discardableResult\n    private func reorder",
            in: source
        )
        XCTAssertTrue(
            entryDropSlice.contains("if sortOption == .manual {\n            // In manual order, dropping on another material means reorder")
                && entryDropSlice.contains("return reorder(source, after: target)"),
            "手動ソート中に資料を別の資料へドロップしたときは、新規フォルダを作らず reorder(source, after: target) で並び替える必要があります。"
        )

        // 2. reorder: 同一フォルダ内のみ許可し、targetIndex + 1 に挿入して 0..<count の連番を振り直すこと
        let reorderSlice = try sliceFunction(
            "private func reorder(_ source: HomeEntry, after target: HomeEntry) -> Bool",
            until: "private func uniqueFolderName",
            in: source
        )
        XCTAssertTrue(
            reorderSlice.contains("guard source.underlying.folderName == folderPath else { return false }")
                && reorderSlice.contains("entries.removeAll { $0.id == source.id }")
                && reorderSlice.contains("guard let targetIndex = entries.firstIndex(where: { $0.id == target.id }) else { return false }")
                && reorderSlice.contains("entries.insert(source, at: targetIndex + 1)")
                && reorderSlice.contains("for index in entries.indices { entries[index].sortIndex = index }"),
            "reorder は同一フォルダ内のエントリのみを対象とし、target の直後に移動して連番の sortIndex を振り直す必要があります。"
        )

        // 3. handleFolderDrop: 手動モードでのフォルダ移動時は nextManualIndex を付与し、保存失敗時は元の sortIndex も復元すること
        let folderDropSlice = try sliceFunction(
            "var movedItems: [(item: any HomeItem, folder: Folder?, path: String, updatedAt: Date, sortIndex: Int)] = []",
            until: "private struct FolderMoveSnapshot",
            in: source
        )
        XCTAssertTrue(
            folderDropSlice.contains("if sortOption == .manual {\n                    item.sortIndex = nextManualIndex(in: destination?.legacyPath ?? \"\")\n                }")
                && folderDropSlice.contains("previous.item.sortIndex = previous.sortIndex")
                && folderDropSlice.contains("(entries(inLegacyPath: folderPath).map(\\.sortIndex).max() ?? -1) + 1"),
            "手動モードでフォルダへ移動したときは移動先末尾の sortIndex を割り当て、保存失敗時には元の sortIndex を復元する必要があります。"
        )
    }

    // MARK: - 3. ホーム作成メニューの整理・MCP JSON連携廃止・文字列カタログ自動抽出停止

    func testMCPJsonExportAndImportAreRemovedAndCreateMenuIsStreamlined() throws {
        let source = try contentViewSource()

        // MCP JSON連携のUI文言・メソッドが削除されていること
        XCTAssertFalse(
            source.contains("MCP連携データを書き出す") || source.contains("MCPの変更を読み込む"),
            "廃止された MCP JSON 連携の書き出し・読み込みボタンが残っていてはいけません。"
        )
        XCTAssertFalse(
            source.contains("exportMCPSnapshot") || source.contains("importMCPActions"),
            "廃止された exportMCPSnapshot / importMCPActions 関数が残っていてはいけません。"
        )

        // ホームの「＋」メニューから設定・復元系の重複項目が外され、作成・読み込みに絞られていること
        let plusMenuSlice = try sliceFunction(
            "private var createMenu: some View",
            until: ".accessibilityIdentifier(\"home-create-menu\")",
            in: source
        )
        XCTAssertFalse(
            plusMenuSlice.contains("MCPクラウド連携")
                || plusMenuSlice.contains("バックアップを復元")
                || plusMenuSlice.contains("自動バックアップを復元"),
            "ホームの「＋」作成メニューに MCPクラウド連携 や バックアップ復元 が重複して残っていてはいけません(「その他」タブ側に集約済み)。"
        )

        // 一方で「その他」タブ(MoreHomeView)にはバックアップ復元とMCPクラウド連携が残っていること
        let moreDataSlice = try sliceFunction(
            "private var integrationSection: some View",
            until: "private var friendSection: some View",
            in: source
        )
        XCTAssertTrue(
            moreDataSlice.contains("MCPクラウド連携(Claude・ChatGPT)")
                && moreDataSlice.contains("バックアップを復元")
                && moreDataSlice.contains("自動バックアップを復元"),
            "「その他」タブのデータ・連携セクションには MCPクラウド連携 と バックアップ復元 が残っている必要があります。"
        )
    }

    func testProjectYmlDisablesBothSwiftUILocalizedStringSupportAndLocStringsEmission() throws {
        let projectYml = try projectYmlSource()
        XCTAssertTrue(
            projectYml.contains("LOCALIZED_STRING_SWIFTUI_SUPPORT: NO")
                && projectYml.contains("SWIFT_EMIT_LOC_STRINGS: NO"),
            "ビルド時に Localizable.xcstrings が自動書き換えされないよう、project.yml で LOCALIZED_STRING_SWIFTUI_SUPPORT と SWIFT_EMIT_LOC_STRINGS の両方を NO にする必要があります。"
        )
    }
}
