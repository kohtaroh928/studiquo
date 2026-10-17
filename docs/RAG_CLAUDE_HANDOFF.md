# Studiquo RAG：Codex / Claude 共通の引き継ぎ

最終更新: 2026-10-18。次担当はこの要約を入口にし、実ファイル・git状態・最新のユーザー指示を優先する。過去のチャット全文を読み直す必要はない。これは実装の現在地で、タスク管理の正本は既存Notionカード。

## 共同開発キットのGitHub保存（2026-10-18）

- ユーザーが公開作業を明示依頼。共有対象はAGENTS/CLAUDE/INDEX、共同開発ガイド、collaboration/rag-promptの8ファイル、この引き継ぎ。アプリ差分、生成.local/cache/output、以前のローカル再開テスト報告2ファイルは含めない。
- 保存先は既存codex/rag-wip（mainへのmergeやdeployではない）。公開commitはgit logとremote branchのSHA一致で確認する。友人はdocs/RAG_COLLABORATION.mdから独立cloneを作り、START_PROMPT.mdを使用する。
- この公開前の再検証はworkspace3＋既存baseline7の10件成功。本番prompt・凍結baselineは不変、候補exampleは品質未評価。有料API0回。秘密情報検査と選別済みsnapshotの確認を行ってから送信する。
- 友人の候補作成/本人PCの確認は未着手。Notionタスク3fc5d67983c381fa9008e37723e0ca04に公開状況を記録する。自動スケジュールPAUSED、本番設定変更なし。今回開始したテストは完了。
- 前回の再開テスト報告はローカルに残り、この共有commitだけのcloneにはない。友人のプロンプト作業は凍結した共有fixtureだけで開始できる。Project用INDEX複製の更新は別途残る。

## 今回の環境整備（2026-10-18、友人の並行開発）

- docs/RAG_COLLABORATION.mdとcollaboration/rag-prompt/を追加。友人は別clone/branchで候補・評価計画、本体担当はDocling/安全境界/iPad接続。PR baseはcodex/rag-wip、本番promptへ直接反映しない。
- キー不要のcheck/prepareで凍結合成6ケース×2styleの12組を生成。質問/根拠/生成設定を保持し、候補の指示追加だけを変更。新しい回答生成なし、品質未評価。
- 担当別HANDOFF/START_PROMPT/PROPOSALとAGENTS/CLAUDEの入口を整備。友人は共通handoffを編集せず、担当HANDOFFを更新し本体担当が集約する。既存同一worktree交代とは別。
- 検証: workspace3＋既存baseline7の10件成功。HEAD clean export＋kitでnode_modules/credentialsなしにcheck/prepare成功、同名run上書き拒否/無効run名3件拒否、.local Git除外を確認。既存本番prompt・凍結資料の変更なし。
- Notion: 初回候補用タスク https://www.notion.so/3fc5d67983c381fa9008e37723e0ca04 を未着手で追加。友人の担当欄は既存schemaにないため未設定。既存RAGカードは進行中を保持。
- 環境整備当時の公開状態: 未コミット・未push（上の公開作業記録を優先）。友人のPC/権限/ログインは未確認。有料API0回、スケジュールPAUSED、配備なし。今回の検証processは完了。
- 次の一手: 環境整備のみのGitHub保存を確認後、友人が独立cloneしてcheck/testし、候補一つと採点計画をPR。Project資料はINDEX複製の更新が必要だが今回置き場は変更していない。

## 今回の確認（2026-10-18、未実装項目の照会）

- 実ファイル・残実装計画・最新テスト記録を確認し、未実装と未検証/未配備を分けて回答する。アプリ/サーバーのコード変更とテスト再実行はなし。前回のProject資料18件更新・iPad134/UI3成功は以前の結果として保持。
- 未実装/未接続: 原PDFからDoclingへのアプリ自動解析全経路、その経路専用の別同意・本人/文書世代・費用予約・取消削除の呼出元、実encoder接続、図/OCR/数式の解釈と索引対応、精密bbox遷移、本番の要求分解/回答漏れ検査・修正、解析job記録の保持整理・予算/運用監視。
- 既存ホーム資料の登録/検索許可・認可・失効制御は実装済みで、上記新原PDF解析の未実装と混同しない。Docling構造抽出、prepared取込、metadata、再帰分割、ページ単位出典、private runner/Container制御もローカル実装済み。
- 別の残件: Linux/Cloudflare実環境、実機/旧実store/iCloud、実資料・新API回答品質、リランカー実比較、main統合/配備・0009適用。本文の意味分割はvectorsなしの現状でsemanticApplied=false。Qwen/Cohere交換を実施済みとしない。
- 次の一手は原PDF自動解析の未接続部分と実encoder接続の優先順位を決め、既存計画に沿って実装。質問への回答のみで新機能実装を開始していない。このターンが開始した実装/テストprocessはなし。Notionは既存RAGカードへ確認結果を追記する。Project用複製の追加更新は不要。

## 今回の作業終了時点（2026-10-17、Project更新・テスト再開）

- ユーザー依頼でDesktopのProject用資料18ファイルを更新。11複製は正本とのbyte一致確認、残り7件は現状資料/README。旧Google説明、プランの利用枠、RAG構造解析・自動原PDF未接続などの現状を反映。claude.aiへのアップロードは未実施（人間が同名旧資料と差し替える運用）。人物像の手記ファイルは未変更。
- テスト再開: 署名付きiPad simulator関連12suite・134件とRAG UI3件が成功。出典から3ページ目への遷移、検索状態表示、検索データ管理も確認。今回アプリソースは変更せず、以前からの無関係な未コミット変更を保持。
- 固定の旧4候補24回答から差分要求8回答をoffline再確認。記述あり5/欠落3で以前と同じ。新回答や現在のLunaの精度測定ではない。有料API0回、未使用20問を調整に使わず、本番prompt変更なし。
- 根拠: docs/RAG_TEST_RESUMPTION_REPORT.md / RESULTS.json。今回はこの報告とhandoffがローカル未コミット。直前の実装は9ed298d、引き継ぎ追記09e2a7eでGitHub codex/rag-wipへ保存済み。
- 未完: 実機/旧実store/iCloud、Linux/実Cloudflare、原PDF別同意・認可・admission・取消削除とMCP/iPad接続、実encoder、図/OCR/数式・実資料品質・精密位置遷移。次のAPI品質試験は費用・版・モデル・件数を固定して別測定する。
- 直前push時のサーバー1723/Worker28/processor60/tools49成功は今回のアプリ137件と区別する。自動スケジュールはPAUSED。deploy/remote migrationなし。

## 1. 再開する場所

- 同じMac: `~/studiquo/.worktrees/rag-wip`
- ブランチ: `codex/rag-wip`。最新commitは`git log -1`で確認。GitHub: https://github.com/kohtaroh928/studiquo/tree/codex/rag-wip
- 今回RAG成果を専用branchへ選別保存する。mainには統合しない。同じMacには対象外の未コミット変更が残るため、branch切替・stash/reset/clean・一括commitを行わない。別のMacでは専用branchを使い、ローカルruntime/model/資格情報は別途用意する。
- CodexとClaudeを同じファイルで同時実装させない。交代前に前担当の処理・テスト・編集が止まっていることを確認。今回の引き継ぎ準備時点でRAG実装のバックグラウンド作業は依頼していない。
- Claude Code実行ファイルは確認済み（`~/.local/bin/claude`）。ログイン状態・契約・残量は確認していない。資格情報は読まない。
- 移行する場合は未追跡も含む作業データを別途安全に保存する必要がある。秘密/資料/ローカルmodelを無差別にGitや共有へ入れない。今回のpush依頼は選別したRAG成果のみを対象とする。

## 2. 最初に読む順番

1. `AGENTS.md`、Claudeでは`CLAUDE.md`も読む。
2. この資料 → `docs/RAG_REMAINING_IMPLEMENTATION_PLAN.md`。
3. 直近の正本: `docs/RAG_DOCLING_CONTAINER_BOUNDARY_REPORT.md` と `RESULTS.json`。
4. 担当する工程に必要な設計: `docs/RAG_DOCLING_AUTOMATIC_PROCESSING_DESIGN.md`、`services/docling-worker/README.md`、`services/docling-container/README.md`。
5. High変更に進む前に`docs/DEVELOPMENT_WORKFLOW.md`を全文読む。`docs/HYBRID_RAG.md`は全体背景、`docs/RAG_AUTONOMOUS_HANDOFF.md`は過去の経緯として必要箇所だけ確認する。後者の古い「未実装」「中断」を最新状態と混同しない。

## 3. 実現したいことと現在の仕組み

Studiquoのホームの本人資料をAIチャットが探し、根拠を示して説明できるようにする。資料確認(source_only)と学習向け解説(explain)を分け、資料の事実・一般補足・仮定例を混同しない。AIチャットの提供先はOpenAI（Standard=Luna）。RAG用embedding/rerankingはCloudflare Workers AI。

既存検索はBGE-M3 embedding/Vectorize + D1全文検索→RRF→BGE-reranker-base→認可済み出典/neighbor→OpenAI。本人・同意・文書範囲・削除状態を再確認する。リランカー比較は候補調査で、Qwen/Cohereへの交換は未実施。

Docling2.139.0で構造を抽出し、本文(text/paragraph)だけに意味境界（明示vectorsがある場合）→再帰分割を適用、表/見出し/図/数式等は保護要素として分離する。実encoderの自動接続はまだなく、現行実動作はsemanticApplied=false/no_vectors。OCR・数式enrichmentはoff。図/未知/要確認/空page/過大要素などを勝手に捨てず、prepared exporterは資料全体を拒否する。

## 4. ローカル実装済み

| 範囲 | 主な場所 | 状態 |
| --- | --- | --- |
| 構造解析/分割/metadata/export | tools/docling/ | 固定localモデルで合成PDFの実解析確認 |
| 構造索引/metadata保存・出典 | mcp-server/src/rag/、migrations/0009_rag_metadata.sql | optional strict入力、D1 metadata_json、旧形式互換。remote migration未適用 |
| iPad構造import/保存/索引/出典 | RAGStructuredDocument/Attachment、RAGIndexingService/LibrarySync、Notebook、RAGCitationMetadata等 | 原PDF hash一致prepared import、暗号化保管・編集失効・capability確認、ページ出典。実機/iCloud移行未確認 |
| 有限Python runner/HTTP | services/docling-processor/ | 10MiB/20page/期限/取消/清掃、localとcontainer入口を分離 |
| private Container制御 | services/docling-worker/ | default flag false、public404、単発DO、期限/取消/破棄確認後返却、本文非保存。既存MCPへ未binding |
| Linux recipe | services/docling-container/ | offline hash lock/wheels/models必須のrecipe。未ビルド |

Docker/Podmanは確認時点で無い。Linux依存lock/wheels/base digest/model同梱を準備していない。実Cloudflare VMの起動/通信隔離/停止/破棄は未確認。型生成・bundle成功だけで稼働可能としない。

## 5. 直近の検証記録（今回の引き継ぎ準備では再実行していない）

- private Worker JS 28件、独立レビューも同28件成功。
- Python services 60件（Container14/HTTP27/runner17/child2）とtools/docling49件成功。
- Worker実コード（DOはNode shim）→実Node fetch→Python HTTP→実offline Docling、合成2page・parse POST1回・6.11秒・helper停止後返却・job削除。VM lifecycleはmock。
- 直近全mcp-server: 1723件成功は前工程の記録。iOS関連98件＋後の関連36件は重複あり。今回全iOS/Workerを再確認したとは扱わない。
- 最新REPORT/RESULTSにsource hashがある。現在のファイルと一致しなければ後続変更を調べ、古い成功結果を現コードへ流用しない。証拠として残す報告や凍結fixtureのhashを辻褄合わせで更新しない。
- テスト件数や合成smokeは実利用者資料での回答精度改善を証明しない。

## 6. 次の具体的作業

最初に実ファイル/既存Notionを確認し、次の2本を区別して進める。

A. Linux実行確認: Docker実行環境、review済Python3.12 base digest/native共有library、Linux用全transitive hash lockとoffline wheels、model inventory、license/脆弱性を確認する。macOS freezeをLinux lockと偽らない。root contextのDockerfile.dockerignoreを使い秘密/資料をbuilderへ渡さない。Docker/課金/配備のユーザー操作が必要なら具体的な不足だけを記録し、準備済みとしない。

B. **Aが外部環境待ちでも進められる実装**: 原PDF専用同意とepoch、canonical本人/文書generation、admission/利用量予約、job IDと本人の対応、取消/削除/アカウント削除の呼出元を設計・テストしてから既存MCP/iPadへ接続する。JSON用privacy body readerを原PDFへ流用しない。公開route/新外部送信は未完成のまま有効化しない。大きい変更は独立Planner→実装→Code/Security review。

その後、実環境でのHost/Content-Length互換、alarm/storage gate、cold start、native memory/ネットワーク、取消/破棄/保持/費用を検証する。最終的に原PDF選択→解析→構造索引をiPadで接続する。普通のNotebookは原PDFを保持していないので既存資料は再選択等が必要。自動encoder、図/OCR/数式、日本語/100page品質、精密bbox遷移、実機/既存store/iCloud、リランカー実比較は別の未完項目として残す。

## 7. 維持すべき境界と既知の注意

- ユーザーは通常判断を自律的に進めることを承認済み。通常の可逆実装・必要なテストを都度確認で止めない。一方、明示依頼のないdeploy/remote migration/push/merge/release/追加購入/新有料評価はしない。
- RAG flagsと新execution flagは既定false。自動スケジュールstudiquo-ragは**PAUSED**。Claude起動や交代は自動スケジュール再開の許可ではない。
- 両サービスの制限・許可はそれぞれ守る。設定/キー/アカウント切替で同じサービスの制限を回避しない。アプリのOpenAI/Luna設定を開発担当のClaude切替と混同して変更しない。
- 構造metadataやPDF digestは認可ではない。原PDF別同意・本人・generation・削除条件を接続前に実装する。RPC切断は自動伝播を仮定せず明示cancel。
- DO blockConcurrencyWhile callbackは例外を外へ出すと実runtimeがresetする。outcome化しgate外で固定error。storage障害でもdestroyを独立して試す。重複拒否で先行jobを停止しない。
- 永続storage自体が故障するとpoison/alarm保存不能になり得る。in-memory停止とdestroy試行はするが、停止不明は運用確認が必要。tombstone retention、予算/監視も未設計。
- Worker status disabledの旧応答shape、旧アプリ/旧DB互換を維持。0009未適用なら新構造を黙って送らない。
- iPadの既存in-memory persistence testはcloudKitDatabase:.noneを明示して隔離済み。assertionを弱めて解決しない。XcodeGen再生成時はApple Sign In/CloudKit capabilitiesを確認。

## 8. 評価資料を守る

開発30問と未使用20問を区別し、未使用20問を調整に使わない。本番prompt出力v1維持、A/C候補は不採用。完了したsubject-role比較runを再開/追加送信しない。凍結RAG_CLARIFICATION_FIXTURE/VALIDATOR/REVIEW_RESULTS等は承認なく作り直さない。

完了run（存在確認が必要、tmpは消え得る）: `/private/tmp/studiquo-rag-subject-role-live-20261016-01`、runId `b0fc8f2f-cda7-4aa7-afd4-ca8d2bab73fd`、manifest SHA `3be1b351bb6f7c9787415ea568e3710b0bc2dde17396cdec6285b8a81a100744`。秘密や本文を読んで出力しない。APIキーの読取・新しい有料runは今回の再開指示に含まれない。

## 9. 必要なときの検証コマンド

作業rootで実行。以下はテストであり有料LLM呼出しではない。loopback権限は各ツールの正規手順を使い、拒否を回避しない。

```sh
node --test services/docling-worker/index.test.js
/private/tmp/studiquo-docling-env/bin/python -B -m unittest discover -s services/docling-processor -p 'test_*.py' -q
/private/tmp/studiquo-docling-env/bin/python -B -m unittest discover -s tools/docling -p 'test_*.py' -q
```

`/private/tmp/studiquo-docling-env`と`/private/tmp/studiquo-docling-models`は同じMacの一時資産。消えていたら勝手にruntime/modelを取得せず必要性と許可を確認する。fixture子processだけのテストと実Docling smokeを区別。全mcp変更時はmcp-serverでnpm test、iPad変更時は該当Xcode testを追加する。Xcode派生成果/生ログはprivate tmpに置く。

## 10. タスク・資料・交代の記録

既存Notion: https://www.notion.so/3f65d67983c381a1aebcd7d88d227f9d （RAG回答の残る弱点を評価・改善する）。作業着手/終了を同じカードへ追記、既存経緯保持。接続できなければ未記録と明示し、local資料に次回追記内容を残す。重複カードを作らない。

CodexはRAG関連の作業を終えて最終応答を返す前に毎回、確認を求めずこの資料を更新する。実装・調査・テスト・文書修正・途中中断も対象。進捗がない場合も事実と理由を書く。重要な区切り・交代前・制限が近いときにも「最終更新/今回行ったこと/現在地/次の作業/今回の検証と未実施項目/途中process/未解決/Notion記録」を更新し、長い経緯は既存RAG_AUTONOMOUS_HANDOFFへ追記する。ClaudeからCodexへ戻すときも同じ資料を使う。実行中のprocessがなければ「なし」と書く。チェック不能を停止済みと捏造しない。

今回引き継ぎ準備で変更したのは文書と再開用入口だけ。既存実装・課金・提供モデルは変更せず、Claude本体を起動していない。引き継ぎ時点のRAG実装編集/テストprocess: なし（この会話内で最後に起動したものは完了確認済み。他セッションは次担当が再確認する）。

Project複製の差し替え残件: ARCHITECTURE/DATA_AND_MIGRATIONS/SECURITY_AND_PRIVACY/HYBRID_RAG。今回Desktopの複製・claude.aiへのuploadはしていない。

## 11. Claudeへの渡し方

同じMacのClaude Code: 作業rootから`./tools/resume-rag-claude.sh`を実行し、初期promptに従って資料を読ませる。起動helperはbranch/必要file/CLIを確認するだけで、Git変更・キー移行・permission bypassをしない。認証や権限が必要ならClaude側の通常画面で扱う。

通常のclaude.aiチャットを使う場合: この引き継ぎ資料・再開promptと、担当工程に必要な設計/ソースだけを明示選択して渡す。ローカルの未コミットworktreeを読める環境か確認し、アクセスできなければ実装済みと主張させない。GitHub接続だけでは未コミット/未追跡の成果は取得できない。チャット履歴の自動共有や利用量上限での自動切替は今回設定していない。

公式手順: https://code.claude.com/docs/en/quickstart 、https://code.claude.com/docs/en/memory 。
