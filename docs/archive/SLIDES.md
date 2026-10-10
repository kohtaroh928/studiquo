---
title: スライド機能の保管メモ
date: 2026-10-10
tags: [archive, slides]
---

# スライド機能の保管メモ

リリース前に、スライド機能をアプリ本体から取り除いた。リリース後のアップデートで復活させる予定のため、完全な状態をgitに残している。

## 保管場所

- タグ: `archive/slides-v1`(コミット `a545333`、除去直前のmain)
- ブランチ: `archive/slides`(同じ位置。タグを見落とさないための目印。更新しない)

確認:

```bash
git show archive/slides-v1 --stat
git ls-tree -r archive/slides-v1 --name-only | grep -i -E 'slide|pptx'
```

## 取り除いたもの

| 区分 | 内容 |
| --- | --- |
| ビュー | `Views/SlideDeckView`、`SlideCanvasEditor`、`SlideMasterEditorView` |
| モデル | `Models/SlideElement`、`StudyDocument.swift`内のスライド節(`SlideDeck`、`Slide`、`SlideTheme`、`SlideLayout`、`SlideAspect`ほか)、`SlideMaster`、`SlideLayoutTemplate`、`SlidePlaceholder` |
| サービス | `Services/SlideTextFormatting`、`PptxReader`、`PptxWriter` |
| テスト | `SlideDeckEditingAndPresentationTests`、`SlideElementTests`、`SlideTextFormattingTests`、`PptxReaderTests`、`PptxWriterTests` |
| 結線 | `ContentView`(タブピッカー・サイドバー・タブ・新規作成・MCP取り込み)、`Folder.slideDecks`、`HomeItem`/`HomeSelection`の`.slideDeck`、`StudiquoApp`のスキーマ登録、`ExportService`(PDF)、`AIAppAttachmentCatalog`、`AIChatAttachment`、`slide:`ドロップ、`ExternalDisplayController`の投影など |
| MCP | `mcp-server/src/app.js`の`create_slides` |

## 復活手順

1. `git diff archive/slides-v1 main -- studiquo studiquoTests mcp-server` で、除去後の本体との差分を見る。
2. 削除したファイルを `git checkout archive/slides-v1 -- <path>` で戻す。
3. 結線(上表の「結線」)を、当時のコミットを参考に再度入れる。本体側が変わっているため、そのままの再適用はできない。
4. SwiftDataのモデルとスキーマ登録を戻す。これはHighリスク変更なので、`AppSchemaCloudKitCompatibilityTests`、`StoreSchemaTests`、既存ストアでの起動確認、CloudKitの互換確認を行う。
5. `project.yml`を変更した場合は再生成し、Apple Sign InとCloudKitのCapabilitiesを確認する。
6. MCPの`create_slides`を戻す場合は、新旧バージョン間の互換性を確認し、アプリ→Workerの順で更新する。

## 注意

- 除去時点で、スライドのテストに既知の失敗があったかは確認していない。復活時にテスト全体を実行して確認する。
- 除去後に`DocumentBlock`など共有部品が変わると、保管したスライドのコードはそのままではビルドできない可能性がある。
