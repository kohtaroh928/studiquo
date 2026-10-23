# RAG検証候補の版固定（Step 1）

2026-10-19。対象 `codex/rag-wip`、基底commit `c6faf5d9fd0a5014a661e4533a1dfdc22e696523`。既存変更は移動・破棄・stageしていない。新commit、push、remote migration、配備なし。

## 固定した対象

[機械可読一覧](RAG_VERIFICATION_BASELINE_20261019.json)に、MCPサーバー・Docling Worker/processor/container・Doclingツールの実装、テスト、依存lock、migration、設定を固定。374ファイル（HEAD未追跡の追加27を含む）の相対path・bytes・SHA256と集合hashを記録した。ファイル選択範囲/拡張子/除外規則も一覧内に記載。HEADから変更のない依存先も含む。

集合SHA256: `826b845b0633666b4ba53ae5284ce57443eee7a23bc21797e2db53d6e1a0a5c4`。

Linux provisioningはignoredのまま、lock・wheel inventory・model inventoryの3つのhashだけ記録。wheel/model本体のコピーは行わない。image IDと過去Linux実試験は[RAG_LINUX_PUBLIC_CONNECTION_REPORT](RAG_LINUX_PUBLIC_CONNECTION_REPORT.md)を参照。現在VMを起動してimage内容を再照合した結果ではない。

## 差分の分類

| 分類 | 扱い |
| --- | --- |
| RAG本体の実行・検証候補 | ai-privacy/app/worker、原PDFの0010〜0013とpdf-*、staging/local例設定、Docling起動修正・Linux準備/試験を含む。実行flagはfalseの現状を記録 |
| RAG設計/検証記録 | docsのRAG報告・採用設計・保持復旧・HYBRID_RAG/DATA/SECURITY等。実行対象一覧とは別の説明資料 |
| 共同担当の準備 | collaboration/rag-prompt/HANDOFF・API_ACCESS、RAG_COLLABORATION。APIアクセスの招待送信記録、候補実装とは別 |
| 既存の別アプリ作業 | StudiquoApp、ContentView、FlashcardDeckView、FolderMigrationServiceTests、DocumentViewNavigationBarTests。今回のサーバー/Docling候補には含めない。iPad工程では改めて確認 |
| ローカル生成物/別記録 | .wrangler、output、docs/.obsidian、接続確認メモ。一括追加しない。生成領域の本文や秘密は読まない |

候補にはサーバー全体の設定ファイルも入る。これを全環境へ配備する許可ではない。本番private bindingはなく、配備対象・環境別差分は次工程で確認する。

## 検証と限界

一覧生成後に別の照合処理でファイル集合/欠落/サイズ/hash/集合hashと除外境界を検証した。不一致0。変更hash・欠落・余分な対象ファイルの模擬検出も確認。git diff --check成功。

今回の作業は棚卸しとhash固定で、機能コードを変更していない。サーバー1851/processor61/provision6件の成功は前工程の結果で、今回再実行したとは扱わない。内容の品質・秘密の完全走査・remote可用性をhash一致から主張しない。

これは**照合用の版固定**で、ソース本体の不変archiveやGit commitではない。対象が後で変更されたら、この一覧を更新して過去成功に合わせず、差分を確認して新しい候補IDで作り直す。後の配備には、対象版の保存とその版での再検証が必要。既存の前工程REPORT/RESULTSのhashは変更していない。

Step 1は完了。次はStep 2のstaging既存版・DB更新状況・料金条件の読み取り確認。配備承認は引き続き別で、今回の完了で取得した扱いにしない。
