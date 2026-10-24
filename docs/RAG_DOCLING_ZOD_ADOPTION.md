# DoclingとZodの導入

2026-10-16。ユーザー依頼によるfull手順。実装作業先はcodex/rag-wip。本番へのdeploy/資料送信は含まない。

## 受け入れ条件と責務

- Doclingを実利用するローカルPDF解析CLIを追加する。見出し・本文・表とページ由来を構造化JSONへ保持し、ページ単位の既存RAG入力へ変換可能にする。外部URL・任意ファイル形式・暗黙のモデル取得・解析内容のログ出力・自動uploadは許可しない。
- 実行環境とモデルの準備を解析実行から分ける。実PDF解析は合成PDFで確認し、実行できない場合はその理由を残す。モデル未配置で成功したことにしない。
- Zod4は既存dependencyを使用。AIのrubric/grade/review構造化出力で、送信用JSON Schemaと受信検証を共通のZod定義から作る。欠落・未知項目・型違いは修復/型変換/項目削除せず拒否し、既存のエラー通知・クレジット返還経路へ流す。
- 聞き返しcandidateにも新Zod wire schema/response parserを追加し、既存の凍結pure validatorへ接続する。正解/harness/reviewはモデル入力へ渡さない。新規通信やruntimeへの聞き返し機能接続は行わない。
- 通常チャットのMarkdown回答はJSONに変換しない。意味評価・出典照合・認可はZodの形式検証とは別に維持する。

## 実装計画

1. 独立Plannerが既存端末内抽出/Worker登録/構造化出力を調査する。
2. tools/doclingに固定依存・CLI・構造変換・テスト・使い方を追加。既存iPad抽出経路と既存DB schemaは変更しない。
3. ai-output-validation.jsでZod出力検証を実装しstreamJSONに接続。整数の既存wire範囲は変更せず、採点の数値的/意味的正しさを保証したとはしない。
4. 別clarification candidate入出力にZodを使用。既存oracle/run/validator/source hashは維持する。
5. 対象/全Worker/Python検証と独立コード・安全レビュー、文書/Notion更新。

## 脅威・障害と停止方法

Doclingはローカルで明示指定したPDFだけを処理。Python/モデル用の別環境が必要でWorkerやiPadに直接載せない。解析結果は学習内容を含み得るので、指定した新規ファイルだけへ出力し通常ログへ保存しない。PDFsha256は入力ファイルの同一性であり、既存ingestの抽出テキストsourceHashへ代用しない。認可/consent/lockedやアプリ文書との対応が未接続のため、本番の自動同期でDoclingを使う段階ではない。

構造化出力は完了イベント確認に加えZodで検証。拒否・不完全・不正型は結果として返さず既存返還経路を通す。生Zod errorは本文を含む可能性があるため公開/ログ化せず固定codeのみ。再生成リトライを追加しない。未検証のstream断片は確定結果にしない。

新CLIを使用停止すれば既存抽出へ影響しない。Zod接続のrollbackは今回の検証箇所だけを既存JSON解析へ戻せるが、不正shapeを許容するので基本は修正を優先する。新API/DB migration/設定/同意文言/本番送信先の変更はない。

## 外部仕様

公式DoclingのDocumentConverter/PdfPipelineOptions/offline設定、Zod4のstrictObject/safeParse/JSON Schema、OpenAI DocsのStructured OutputsとCloudflare Workers best practices本文を確認した。依存やモデルの準備は別途記録し、実API受理と回答精度をテスト成功から推定しない。

## 検証結果

- 既存AI36＋Zod7＋candidate7の対象50テスト成功。未知/欠落/型/enum/byte上限・拒否/未完了・SSEと日本語UTF8の分割・不正SSE・エラー時に全予約を一度ずつ返還することを確認。通信は全てmockで実OpenAI APIの受理ではない。
- 最終全Worker1,707成功、失敗/skip0。ログは `/private/tmp/studiquo-docling-zod-worker-final2.log`。
- 旧HEADのrubric/grade/review schemaを抽出し、既存strict変換後とZod生成schemaのexact deepEqualを確認。形/必須/enum/整数範囲を変更していない。
- Python16テスト成功、専用Python3.12環境のpip checkも整合。実Docling2.139.0で合成PDF2ページを解析し、8要素/2表とページ由来・0600出力を確認。実装担当に加え親も別出力先で実smokeを再実行成功。実ユーザー資料は使っていない。詳細は [Docling検証](../tools/docling/VALIDATION.md)。100ページの境界テストはmockであり、実推論品質とは区別する。
- 独立Planner/コード安全レビューでcandidateの完了envelope検証不足Mediumを発見し修正。object/model/error/incomplete/usage/reasoning/出力件数の矛盾を拒否する回帰を追加。最終独立対象50・Python16成功、未解決High/Mediumなし。
- 凍結fixture/validator/意味reviewの記録source hash一致と、完了済み実runの固定manifest hash一致を確認。旧source/runは変更しない。今回のOpenAI API/キー読取0、モデル/依存の公開ファイル取得は明示準備として実施。

## 現在の到達点と残件

Doclingは開発者が明示実行するローカル解析として利用可能。見出し・表等の構造JSONを保持できるが、現行indexはpages.textを使うため構造elements/座標が全て検索metadataへ入るわけではない。アプリからの自動利用には解析サービスの配置・送信範囲・同意/認可・文書対応・削除/失効を扱う別実装が必要。OCR/数式profile、日本語実資料・実100ページの精度と性能、依存/モデルのライセンス・脆弱性監査は未完了。

Zodは構造化AI3経路に接続済み。通常チャットの意味・引用の自動検証を導入したものではない。聞き返しcandidateの実API/有限transport/意味reviewは未接続。型検証や合成PDFの成功をRAG回答精度の改善とは主張しない。

自動実行はPAUSED維持、deploy/migration/push/mergeなし。Projectの資料の更新が必要: [設計] HYBRID_RAG.md（複製を差し替え）。複製の置き場は更新していない。
