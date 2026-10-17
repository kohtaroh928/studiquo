# Studiquo RAG：Codex / Claude 共通の引き継ぎ

最終更新: 2026-10-17。次担当はこの要約を入口にし、実ファイル・git状態・最新のユーザー指示を優先する。過去のチャット全文を読み直す必要はない。これは実装の現在地で、タスク管理の正本は既存Notionカード。

## 今回の作業終了時点（2026-10-17）

- 今回の依頼: ユーザーがRAG開発成果のcommit/pushを明示承認。既存のGitHub `codex/rag-wip`へ保存する。mainへのmerge、deploy、remote migrationは行わない。
- 保存対象: RAG本体、OpenAI統合と必要なiPad依存、Doclingのローカル実装・private Worker・Linux recipe、合成評価fixture、テスト、設計・検証記録、引き継ぎ。ページ編集のRAG失効処理が使うNotePageHistoryと対応テストも依存として含める。
- 除外: 生成cache・評価の生出力・エディタ設定・無関係な画面/navigation/folder rename変更。残るローカル変更は保持。部分stageしたContentView/StudiquoAppではworking treeとcommitの差を確認する。
- 検証とpushの最終結果はgit logと既存Notionカードを確認する。この文書はcommit直前に更新するため、push成功の証明はremote branchのSHA一致とする。
- 今回の再検証: mcp-server 1,723件、private Worker 28件、Python processor 60件、Docling tools 49件が成功。Swiftはstageしたソースの構文確認を実施。iOS実行テストは今回再実行しておらず、第5節の過去結果と区別する。有料API評価は実行していない。秘密情報検査・最終stageの独立レビュー後にpushする。
- 次の一手: 第6節のLinux実行確認と原PDF別同意/認可/admission/取消削除の呼出元。実Linux/Cloudflare、MCP/iPad自動処理接続は引き続き未完。既存評価の成功を回答精度改善や配備完了と混同しない。
- 自動スケジュールはPAUSEDを維持。Codex/Claudeの同時編集を避ける。

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
