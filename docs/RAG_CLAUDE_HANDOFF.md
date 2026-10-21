# Studiquo RAG：Codex / Claude 共通の引き継ぎ

最終更新: 2026-10-21。次担当はこの要約を入口にし、実ファイル・git状態・最新のユーザー指示を優先する。過去のチャット全文を読み直す必要はない。これは実装の現在地で、タスク管理の正本は既存Notionカード。

## 英字の別名で落とす問題の検討（2026-10-22、最新）

- 質問が英字、資料がカタカナ・漢字のとき正解を落とす問題に、対策案Aの「質問の残りの語が根拠と強く一致するなら残す」と、案Bの「カタカナ形も確認する」を比べた。**効果が測れる方法がなく、コードは変更していない**（9fb2552のまま）。詳細は`docs/RAG_DETAIL_PRESENCE_ALIAS_REPORT.md`、集計は同名の`_RESULTS.json`。
- 根拠: Aは別名0.50〜0.79、資料にない語0.00〜0.67と重なる。Bは言語モデルが必要で、8Bは不正確、70Bは遅い（最大12.8秒、検索の上限10秒）うえ、どちらも関連語を出して答えなしを誤って残す。用語の意味ベクトルの近さも重なる。語句検索の1位を意味検索の上位Kに入っていれば残す条件も、K=3で別名+0・誤り+2、K=10で別名+1・誤り+8で、今の「1位どうしが同じ」がほぼ最適。
- 新しい質問17問（`~/.studiquo-private/rag-real-material-v5/`）: 別名の答えあり7問のうち3問を落とす（英字の確認なしは7/7）、答えなし10問のうち9問を抑える（確認なしは3/10）。v4とv5を合わせると、別名11問中4問を落とし、答えなし24問中23問を抑える（確認なしは6）。
- 判断待ち: 現行維持（推奨）／小文字だけの英単語を検査しない（別名は戻るが小文字の答えなしを防げない。誤りが入れ替わるだけ）／英字の確認を外す／意味の判定（大きいモデル）。アプリのログで`insufficient`・`no_match`の件数を見られるようにすると判断しやすい。

## 英字の固有語の確認（2026-10-22）

- `detail-presence.ts`に、質問中の英字3文字以上の語（英字の部分だけで照合、大文字小文字不問、単位名・一般語・2文字以下は除く）が、根拠・取得した全候補・検索範囲の全文のどこにもないときは根拠にしない確認を足した（カタカナ語と同じ条件。意味検索と語句検索の1位が同じ抜粋なら残す）。詳細は`docs/RAG_DETAIL_PRESENCE_LATIN_REPORT.md`、集計は同名の`_RESULTS.json`。
- 新しい質問26問（実行前に固定、`~/.studiquo-private/rag-real-material-v4/`）: 答えなし（英字の固有語が資料にない）3/14→14/14、英字の語が資料にある答えあり7/8のまま（落ちる1件は修正前からの別原因）、**英字の別名の答えあり4/4→3/4（radarを誤って落とした）**。
- 回帰（合成60問・validation・第2回30問・未見39問）は悪化なし。未見39問の抑制は18/27→19/27（ChatGPTの1件）。Workerテスト2379件中2378件成功。
- 残る課題: 別名（質問は英字、資料はカタカナ・漢字）で正解を落とす。選択肢は、質問の残りの語が強く一致するなら残す、カタカナ形も確認する、意味の判定。単位のない詳細と無関係な質問の判定、金額が別の対象の1件も未対応。
- 型番は数字を含むと資料の書き方（空白の有無）がぶれるので、英字の部分だけで照合する。

## 金額の単位と数値の結びつけ（2026-10-21）

- `detail-presence.ts`に円・万円・億円・ドルを足し、単位つきの数値を「1位の根拠にある、または質問の固有語（カタカナ語・英字）を含む根拠にある」ときだけ有効にした（比較の質問は結びつけない）。詳細は`docs/RAG_DETAIL_PRESENCE_UNITS_REPORT.md`、集計は同名の`_RESULTS.json`。
- 結果: 合成60問・validation・第2回30問は変化なし、未見39問の答えなし抑制は17/27→18/27（無関係なページの単位で通っていた1件が直った）。答えあり対照12/12は変化なし。Workerテスト2374件中2373件成功。
- 直らなかった1件: 1位のページに、質問と別の対象の金額がある場合（単位は合う）。文の単位で対象に結びつける必要がある。別名（アメリカ／米国）に弱くなる点とあわせて検討する。
- 第2回30問・未見39問は調整済み。次の汎化確認には新しい質問を作る。
- Wranglerのトークンは約1時間で切れる。APIが最初の呼び出しで失敗したら`npx wrangler whoami`で更新してやり直す。評価の途中でAPIの1回が時間切れになることもある（やり直す）。

## 答えなし判定の汎化確認（2026-10-21）

- 未見の質問39問（答えなし27・答えあり12、実行前に固定、`~/.studiquo-private/rag-real-material-v3/`に保管）を、修正前（be4cc6c）と修正後（b87641e）で比較した。詳細は`docs/RAG_DETAIL_PRESENCE_GENERALIZATION_REPORT.md`、集計は同名の`_RESULTS.json`。コードの変更なし。
- 答えなしの出典抑制は9/27→17/27。狙った範囲（単位つきの量、資料にないカタカナ語）は2/13→10/13、狙っていない範囲（単位のない詳細・漢字語、無関係）は7/14→7/14。答えあり対照12/12は変化なし（誤って落とさない）。
- 残り10件の原因: 金額（円）が単位の一覧にない、聞かれた単位が無関係なページにあると通る（Aの2件）、英字の固有語は未確認（1件）、単位のない詳細・漢字語は対象外（5件）、天気・首都など普通の語を含む無関係な質問（2件）。
- 次の一手: 単位に円・万円を足し、数値の確認を質問の対象に結びつける。英字の固有語を足す。単位のない詳細と無関係な質問は語の一致では限界があり、意味の判定の設計が要る（別の設計判断）。

## 答えなし判定の修正（2026-10-21）

- 実資料第2回で出典を抑えられなかった答えなし4問に対し、`mcp-server/src/rag/detail-presence.ts`と`retrieval.ts`に2つの確認を足した（求められた単位つきの量が本文にあるか、質問のカタカナ語が検索範囲の全文にあるか。後者は意味検索と語句検索の1位が一致するときは行わない）。詳細と回帰は`docs/RAG_DETAIL_PRESENCE_REPORT.md`。
- 結果: 実資料第2回の答えなしは2/6→6/6、答えありは22/24のまま。合成60問(55/55)とvalidation(10/10)は変化なし。Workerテスト2370件中2369件成功・失敗0。**6/6は失敗を見てから直した結果で、未見の質問での確認が要る。**
- 分かったこと: リランカー(bge-reranker-base)は日本語の言い換えにほとんど反応しない(合成の正解あり55問のうち12問は最高スコア0.005以下)。リランカーのスコアを「関連が薄い」の判定に使うのは不安定で、採用しなかった。
- 残り: 複数数値条件の誤った根拠不足(1件)、別ページ2主題の比較で片方が落ちる(1件)。日本語リランカーの比較。
- `rag.test.ts`の個人情報マスクの検査が全体実行で1回だけ失敗した(単独20回・全体再実行は成功)。チャンクID(乱数)に`4111`が入った不安定さの疑い、未確認。

## 検索の再評価（2026-10-21）

- `claude/rag-ts`（960f83d）の検索を、合成100ページ・60問とvalidation 20問で測り直した。コード・fixture・期待値は変更なし。詳細と比較表は`docs/RAG_REEVALUATION_20261021.md`、生の結果は`docs/RAG_REEVALUATION_20261021_RESULTS.json`。
- 結果: 正解あり55問で必要ページがそろったのは55/55（修正前52/55）。validationの難しい否定10問で不要な出典は5件→0件。validationの正解あり10問は10/10のまま。Workerテストは2358件中2357件成功・失敗0・スキップ1。実Workers AI REST、D1/Vectorizeはローカル代替。約91 Neurons。
- 読み方: この問題群は調整に使ったもの。汎化の証拠ではない。自然な曖昧質問、実Vectorize/実D1/実iPad、実資料は未測定。
- 実資料（気象庁の教科書）は新しい30問を作って再評価した（`docs/RAG_REAL_MATERIAL_V2_REPORT.md`）。必要な根拠がそろったのは22/24、答えなしで出典を抑えられたのは2/6で、合成教材より弱い。弱点: 話題が合うだけで詳細がない質問に出典が付く、複数数値条件の誤った根拠不足、別ページ2主題の比較で片方が落ちる。質問セットは`~/.studiquo-private/rag-real-material-v2/`（リポジトリ外、権限700）に保管。
- `claude/rag-followup`（出力フィルタ・teen審査の修正、JS版）は`claude/rag-ts`にまだ入っていない。回答側の評価をする前に統合が要る。
- 次の一手: 答えなし判定（詳細の有無の確認）の見直し、複数数値条件の根拠チェックの緩和、比較で片方が落ちる選択の見直し（第1回の6/6・合成60問を落とさない回帰つき）、自然な曖昧質問のセット作成、聞き返しの実チャット接続、比較の差分を書かせる指示。分割（Docling接続・セマンティック分割）は、取りこぼしの原因が分割だと確認できてから判断する。
- 環境: `rag-ts`の`node_modules`が削除済みworktreeへの切れたリンクだったので`npm ci`で入れ直した（git管理外）。

## mainの取り込みとTypeScript移行（2026-10-20）

- 作業ブランチ`claude/rag-ts`（`claude/rag-contract`から分岐、Codexは停止中だった）。mainのTS移行（`allowJs`なし・`strict`）より前に分岐していたため、RAGの`.js`が残っていた。mainを取り込み、RAGのJavaScript全て（`src`・`src/rag`・`scripts/rag-quality`・`tools`・`collaboration/rag-prompt`・`services/docling-worker`、計235本）を`.ts`にした。
- 取り込みで手で統合した所: `ai.ts`（mainの与信→審査の順とエラー文言は維持し、RAG検索・`beforeDispatch`・応答のリンク除去・構造化出力の検証・チャット指示文はRAG側を採用）、`openai.ts`（`beforeDispatch`と審査の`timeoutMs`を追加）、`ai-privacy.ts`（`aiPrivacyHeadersRejection`と`ragPrivacyRejection`を追加。RAGの許可検査は本文を複製して読み、`aiPrivacyRejection`の有料化・同意・年齢の検査を通す）、`legal.ts`（RAGの開示項目を追加）、`account-deletion.ts`・`worker.ts`、`wrangler.jsonc`、Swift側（設定のRAG導線、`AIChatView`の資料検索、暗号化ノートのRAG項目消去）。
- 型: `src`は`strict`で通る（暗黙のanyは明示の`any`にした）。テストとスクリプトのうち型エラーのあった127本は先頭に`// @ts-nocheck`を付けた（`src` 80、`scripts/rag-quality` 45、`tools` 2）。型を付けるのは別カード。
- 挙動: 型を消して移行前の`.js`と比べると、235本中231本は同一。違う4本は意図した変更（使い方のコメント、`rag-paired-task-planner-request.test`の固定ハッシュ検査、`rag-subject-role-review`の`rows.map(JSON.stringify)`を同じ結果のアロー関数に）。サーバーのテストは2357件が通り、1件はスキップ。
- 固定した記録: `docs/RAG_*_RESULTS.json`などの`sourceHashes`は移行前の`.js`のハッシュのまま（履歴として残した）。そのため、移行前のソースが変わっていないことを確かめるテストは、`rag-paired-task-planner-request.test`のハッシュ比較を外し、`rag-prompt-baseline`は凍結した`answer-policy.ts`を移行前のバイトのまま置いて通した。`baselines/…/manifest.json`は`sources[].path`だけ`.ts`にし、ハッシュはそのまま（移行後は「変更あり」と報告される）。
- **未解決（D1マイグレーションの番号）**: mainの`0006_legacy_standard_accounts.sql`・`0007_moderation.sql`と、RAGの`0006_rag.sql`・`0007_rag_context.sql`の番号が重なっている。本番・stagingに適用済みの履歴を確認し、番号の付け替えか適用順の決定をしてからでないと、RAGをmainへ入れない。
- 主な残件: Swiftのビルドとテスト（取り込みで衝突を解消した13ファイル）、RAGの経路にmainのAI入口の制限（アカウントごとの1分の回数・購読確認）が掛かるか。

## Step5-B完了：処理済み台帳の有限整理（2026-10-19、最新）

追加0015、内部pdf-purge、writer版条件付出力とA集計の更新、専用23テスト、実local D1再現scriptを追加。初期無効でHTTP/cron/config未接続。0010〜0014は不変、0014のphysical_purge=0とは別制御。新reserveはschemaがあればfloor-v2、既存legacyは保持。初回成功pass後の旧writer拒否はpurge停止後も永続。job identity/window/writerの移動も拒否。

削除はknown created/settled順序、48h、過去UTC窓、intake同世代cancelled/別UUID新世代、registryなし、recovery不在またはdone/lease完全解除のみ。unknown時刻/停止不明/legacy/registry文書/欠落intakeは保持。4stmt D1batchでclocklease/writerfence→coarse partial-index最大10件MATERIALIZEDとnextcursor→範囲内だけeligibility点照合/親DELETE（trigger内floor更新/child削除）→cursor前進/解除。emptyprobeでcursorを巻き戻して保持対象を再確認。child/parent/後続candidate/解除失敗は全rollback。

独立レビューの走査上限Mediumをcoarse候補＋cursorへ修正。DB次秒でlease判定し、初回DBclock＋monotonic残時間とcaller期限のMINで正方向skew延長も防ぐ。後退/24h超gap/5sec超skew/未知契約で閉じ、長期停止後の再anchorは別の運用確認が必要。pre-adoption-v1専用、未知PDF/receipt tableでも閉じる。将来adoption migrationは参照を書き始める前に契約版を変更することが必須。AのphysicalPurgeEnabled診断は両flagをANDするLow修正済み。Code/Security最終再レビュー残所見なし（独立テスト再実行なし）。

最終server1888 pass/0fail/0skip（新purge23含む）。10000held backlogでもcoarse10件/cursor前進/後続ready到達、EXPLAIN index/PK、会計/未精算memory保持、clock/同秒短lease/正方向skew/途中契約参照変更/全rollbackを検証。実local workerd/D1で15migration、同時2pass計3件の一度だけ整理/floor/child削除、parent失敗時全rollbackと未知receipt拒否成功。一時合成DB破棄、今回起動process終了。詳細RAG_PDF_PURGE_IMPLEMENTATION_REPORT/RESULTS。新7ソースhash、古いStep1/Step5A記録は歴史的版として維持。

次はStep6の停止不明claimed/executor token紛失の証拠付き復旧を独立設計/実装し、その契約にStep5-Cのaccount削除phaseを合わせる。A/Bだけで全retention完了としない。DO finite purge/receipt/自動運用/公開/iPad、staging別系統照合/backup/承認・license/OS CVEも未完。rollbackはpurge入口を閉じ、0015/writer fence/floor/失効intakeを保持。旧writerや旧active backupへ戻さない。remote migration/deploy/実ユーザーデータ削除/有料API/commit/pushなし、automation PAUSED。Notion既存カードを更新。Project対象DATA_AND_MIGRATIONS/SECURITY_AND_PRIVACY/HYBRID_RAG、複製/upload未変更、従来リリース00_残タスク表残件保持。

## Step5-A完了：精算時刻・期限切れ受付の詳細削減（2026-10-19、最新）

追加0014、pdf-jobs/recovery/processの時刻連携、内部pdf-retentionと専用14テスト、再現可能なlocal workerd smokeを追加。旧schemaの停止/精算は互換維持、旧settled時刻NULLは推測/backfillなし。全3精算経路の初回時刻はMAX(captured server time, DB次秒)で記録して再送で変更しない。retention用flag/schema/policy gate、expiry partial index＋単一UPDATEで最大10 intakeのcancelled/digest/bytes/request削減、世代/拒否fenceとjob/会計保持。10秒共通待機期限、遅いSQLが後から完了し得ることを明記。集計は固定非識別値のみ、全件走査費用に注意。

controlのphysical purgeはCHECKで0固定、floorは初期0かつ更新入口なし、単調UPDATE/DELETE禁止/INSERT OR REPLACE拒否と旧reserveへのINSERT floor triggerを追加。現Aにjob行削除/48h判定/DO/account/receipt/schedulerはない。RAG_PDF_RETENTION_ENABLEDはconfig未追加、HTTP/cron未接続。

独立Planner/Code/Securityで時刻起算とfloor置換の懸念を修正、再レビュー残所見なし（独立テスト再実行なし）。実local D1でmeta.changesがtrigger更新も数える差を発見し、RETURNING定数の結果件数へ修正して追加レビュー済み。最終server1865 pass/0fail/0skip、実local workerdで0001〜0014とexpiry/trigger/job保持/時刻/aggregate/ORREPLACE拒否成功。runtime検証はsandbox loopback権限不足後に承認済みlocal実行で成功。全検証process終了、一時D1破棄。詳細REPORT/RESULTS。過去374hash baselineは不変、今回8ソースのhashをRESULTSで区別。

次はStep5-Bのclosed-window/48h/永続失効/参照lease/全writer互換を揃えたterminal job＋recovery原子的purgeと失敗試験。先に設計条件と旧writer排除/rollbackを再確認し、Aだけで全retention完了としない。remote配備承認/別系統staging照合/backup・license/OS CVEと停止不明の証拠回復、receipt/iPadは残件。remote migration/deploy/実ユーザーデータ操作/有料API/commit/pushなし、automation PAUSED。Notion既存カード更新。Project資料更新はDATA_AND_MIGRATIONS/SECURITY_AND_PRIVACY/HYBRID_RAG、従来リリース00_残タスク表残件保持、複製/upload未変更。

## Step 4設計完了：保存期間と削除順（2026-10-19、最新）

High/full手順、独立Planner/Code/SecurityでRAG_PDF_RETENTION_DESIGN.mdを作成。intake期限切れを永続cancelledにしてdigest/長さ等を落とす、世代/失効fence保持、未精算/停止不明claimed保持、settled_atから暫定48h＋過去UTC窓＋参照なしだけ詳細整理、recovery child→job parentを原子的削除する設計。単調min_admission_windowと旧writer排除前は物理purge禁止。DOは現2引数RPCで全消去せずspent marker、有限purgeにはimmutable notAfter付きv2/旧RPC排除が必要。

CodeのMedium2件を修正し再レビューで解消: notAfterは実行/採用期限で、期限後の既存VM停止/証拠取得は禁止しない。期限後空DOはdestroy確認しmarker新設/延長なし。PDF pendingを例外にして他account消去phaseまでblockせず、identity消去前のcheckpointと最終全phase判定へ接続する。現deleteAccountRAGはPDF終了を待たないため公開前残件。将来receipt/バックアップ復元による失効巻戻りと停止後再有効化条件も明記。

Security再レビュー含め未解決所見なし（設計のみ）。全migrationを適用したin-memory合成SQLiteで、0unitsのsettled行を削除すると当日COUNTが1→0になる反例を再現。実DB/DO削除、新実装回帰/全サーバー再実行は未実施。固定374source hash一致、diff check成功、機能コード/設定/キー変更なし。計画Step4・DATA_AND_MIGRATIONS/SECURITY_AND_PRIVACY/HYBRID_RAGと採用設計の現在地補正、Notion既存カード更新。

次はStep5-Aの追加schema/精算時刻/互換gate/期限切れintake詳細削減/集計と合成回帰。Bのjob purge、Cのaccount pending、Dのv2 DO/receiptは前提を満たしてから。全retention実装済みとしない。実行中の今回processなし、automation PAUSED、commit/push/配備/remote更新なし。Project更新対象はDATA_AND_MIGRATIONS/SECURITY_AND_PRIVACY/HYBRID_RAGとリリース00_残タスク表、複製/upload未変更。

## Step 3調査完了：OS・モデル利用条件（2026-10-19、最新）

保存済みLinux imageのIDを照合し、network none/host共有なし/read-only/非rootで管理情報だけ読み取った。Debian12 OS429全copyright fileあり、CPython licenseあり。102wheel hashと268license/notice文書、モデル3repo/66artifact hashを照合。UNKNOWN metadata8件を同梱文と公式同版tokenizers LICENSEで補足。Docling MIT、Heron/ONNX Apache2、TableFormer CDLA-Permissive2を固定README revisionで確認。実資料/新モデル取得/再build/配備なし。

RAG_LICENSE_REVIEW_20261019.mdとRAG_LICENSE_INVENTORY_20261019.json、計画を更新。調査完了だがdistributionReady=false。モデルのlicense本文同梱なし、5wheelに独立license本文fileなし（METADATA記載とは別）、GEOS LGPLやOS GPL/LGPL等のnative配布条件履行/第三者noticeレビュー、OS CVE照合が残る。これらをStep8〜9のimage upload/配備前gateとして記録。全体を商用配布可/法的適合/OS安全と断定しない。次はStep4保存期間と削除順の設計。

固定374 source hash一致、件数/hash検証とdiff check実施、機能コード/モデル/依存変更・機能テスト再実行なし。調査container自動削除、VMの正常停止を確認済み。今回実行中processなし。今回新しい有料API/remote変更/commit/pushなし、automation PAUSED。Notion既存カードに結果/残件を追記。Project資料: リリース00_残タスク表へ配布条件gateの反映が必要、複製/upload未変更。

## Step 2調査完了：staging実状態（2026-10-19、最新）

read-only照会とDashboardで現状確認。studiquo-mcp-staging現在version83/660d8caa-f695-4dd0-bddb-4a4aad50995b、100%、2026-10-18 14:42:42 JST。AI_PROVIDER_APPROVED false、RAG flagsなし、AI/Vectorize/RAG rate/private bindingなし。Container一覧0。ADMIN_DBは設定staging DBと一致。schema/既存migration SELECTのrows_written0/changed_db false。未適用0008_rag_control〜0013。remoteにはこの基底にない0006_legacy_standard_accounts/0007_moderationの履歴があるため、後の配備前に別系統更新/remoteソースを照合し保持する。履歴数字で適用済みを推測しない。

Workers Paid契約済み（月$5＋使用量）を現在のプラン表示で確認、公式Containers料金も確認。プラン/設定変更、DB書込、backup、Container起動、deploy/有料LLMなし。D1 migrations listは内部でtable初期化するため使用せずSELECTのみ。初回sandbox通信失敗のエラーJSONは成功/空一覧と区別し、正規権限の再照会成功結果を記録。CLI disk log/telemetry off、連絡先/秘密値は非保存。

RAG_STAGING_PREFLIGHT_20261019.md/jsonと計画更新。固定374 source hash不一致0、機能コード変更/テスト再実行なし。今回実行processは完了、ブラウザ参照のみ。Notion既存RAGカードへ結果追記。次はStep 3のOS依存/モデル利用条件の確認。remote承認、backup/復旧点、アカウントquota/同梱枠残量と配備版の照合は後段の残件。automation PAUSED、commit/pushなし。Project資料の更新が必要: リリース00_残タスク表（staging現状調査の反映、置き場/uploadは未変更）。

## Step 1完了：検証候補の版固定（2026-10-19、最新）

一つずつ進める指示でStep 1だけ実施。既存dirtyを本体/説明資料/共同担当/別アプリ/生成領域に分類、ソースは移動・破棄・stageせず保持。RAG_VERIFICATION_BASELINE_20261019.jsonにサーバー/Docling374ファイル（新規27）と集合SHA256 826b845b0633666b4ba53ae5284ce57443eee7a23bc21797e2db53d6e1a0a5c4を記録、Linux provisioning inventory3点もhash記録。別照合で集合・欠落・サイズ/hash/除外と模擬不一致検出を確認。不変ソースarchiveやcommitではない。前工程成功結果へhashを合わせる改変はしていない。

詳細RAG_VERIFICATION_BASELINE_20261019.md、計画Step 1を完了へ。機能コード/設定/キー/DB/配備変更なし、機能テスト再実行なし、前回1851等の成功は過去記録。今回起動した検証processは完了。Notion既存RAGカードに着手/結果を追記。次はStep 2のstaging既存版/DB適用状況/利用条件の読み取り確認。remote配備承認とは区別。automation PAUSED維持、commit/pushなし。Projectの資料の更新: なし。

## 残件を37単位へ整理（2026-10-19、最新）

ユーザーの依頼で最新コード状態/既存Notion/計画/採用設計を照合し、RAG_REMAINING_IMPLEMENTATION_PLANの先頭へ残件37単位を追記。運用/保持/停止不明回復→staging実環境→receipt/registry採用→iPad→基本版総合評価→意味分割/検索/回答品質→限定公開の順。友人のprompt固定context評価は並行可能。Linuxとlocal workerd/NDJSONは既に済み、remote・iPad採用は未完と区別。古い転送未確定記述は最新のNDJSON実装で更新される。今回コード/設定/キー/費用/配備変更とテスト再実行なし。既存dirty保持。remote配備と有料評価は未承認、automation PAUSED。Notion既存RAGカードに整理結果を追記。今回Project資料の追加更新: なし。次の本体実装は版整理/運用残件調査、remote待ちでもreceiptのローカル実装を進められる。

## 友人への招待送信済み（2026-10-18、最新）

ユーザーの再指示を受け組織表示名をPersonal→Studiquoに保存。組織Reader・対象projectはstudiquo-rag-evaluationだけで招待送信、Invitations一覧で対象を確認。初期Default project選択は解除を確認済み。現在は本人の招待承諾待ち。承諾後に評価projectのMember権限・本人キー・PC設定・モデル/予算を確認する。キー/予算変更や有料APIは未実施。招待先メールは会話だけに保持。Notion共同担当カードとAPI_ACCESS更新。画面証跡はprivate tmp（個人連絡先を含むためcommit不可）。実装/テストprocessなし、commit/push/deployなし、Project資料の更新: なし。過去の招待未送信/表示名承認待ちはこの記録で更新。

## 友人招待の進捗（2026-10-18、最新）

ユーザーから招待送信の明示依頼を受領。評価専用project studiquo-rag-evaluationを新規作成し、画面で存在を確認。project単独追加は「No user found in organization」で不成立。組織招待には表示名Personalの変更が必須とUIに表示された。Studiquoへの保存は自動承認レビューに拒否されたため未変更、明示確認を提示し回答待ち。招待は未送信。APIキー作成/共有、予算変更、有料APIなし。友人メールはユーザー会話だけを参照する。Notion共同担当カードにも現在地を記録。ブラウザは組織名入力dialogでhandoff、今回新しい検証processなし。Project資料の更新: なし（共同担当アクセス準備のみ）。

## 2026-10-18 実Linux・公開HTTP接続（最新）

実Linux amd64コンテナで合成2ページを解析（22.908秒）、通信遮断・UID10001・非書込コード/モデル・取消・期限切れ・SIGTERM・job削除を確認。認証済みローカルworkerd→private RPC→同Linux Docling→最終complete/精算も21.045秒で成功した。Cloudflareへの配備・remote migration・公開URL有効化は未実施で、ローカル成功をremote完了とは扱わない。

公開HTTP handlerは認証後に同意/intake/process/cancelを処理する。受信前認可・予約、転送中の再認可、停止精算後のcompleteを維持。早すぎるResponse返却によるworkerdの入力破棄、isolated Pythonの兄弟import、WranglerのCASE分割を実環境で修正。受付/cleanup/private実行flagsはfalse。本番private bindingなし。staging設定とdry-runを準備済み。

検証: サーバー全1,851件、processor61件、provision6件、HTTP/app/process42件成功。Python102依存のauditは既知脆弱性0・skip0（OS/モデルライセンスの保証ではない）。独立Code/Securityレビューの未解決所見なし。回答品質の有料評価・実資料・未使用20問は使っていない。

詳細・制約・ロールバック: [実Linuxと公開接続の検証](RAG_LINUX_PUBLIC_CONNECTION_REPORT.md)。staging専用のWorker/接続設定/DB更新と合成PDF1件のremote疎通について確認を提示済み、回答待ち。本番変更・プラン変更・追加購入は対象外。次はstagingの既存配備/DB状態と利用条件を確認し、承認後に段階適用・疎通する。iPad正式採用、claimed停止不明の復旧、retentionは残る。

友人用メールは受領済み。現在のDefault projectはprod/stagingと混在しているため、評価専用project新規作成とMember招待を提案したが、作成操作が自動承認レビューで拒否された。明示承認の質問は回答待ち。招待・project作成・キー共有/作成・予算設定は未実施。個人メールはリポジトリ/Notionに複写しない。詳細はcollaboration/rag-prompt/API_ACCESS.md。

今回起動したローカルworkerdと依存準備containerは停止済み。専用Colima VMも正常停止を確認済み。今回実行中の検証process: なし。Linuxイメージとignored provisionedを保持。自動スケジュールはPAUSED。Notionの既存RAGカードと共同担当カードへ結果・残件を追記済み。今回commit/push/deployなし。過去節の「Dockerなし/未build/公開handlerなし」は今回記録で更新される。Project複製/uploadは未変更。


## 停止再試行・集計と次の正式採用設計（2026-10-18、最新）

- 続行指示でfull High/独立Planner→実装→Code/Security観点レビュー。0013_rag_pdf_job_recovery.sql、rag/pdf-job-recovery.ts、専用test、docs/RAG_PDF_RECOVERY.mdを追加。各DB段階/停止RPC候補最大10件、pass10秒、cancel待機2秒、lease30秒、最大3試行/固定backoff。期限切れをstop_requestedへ、未claimだけ安全に0精算。claimedはremote ackでも枠/units保持、元executor精算後だけdoneへ。遅いRPCから台帳更新/精算を再開しない。監視は集計だけ。
- 専用13/全サーバー1,825成功（fail/skip0、全体50.468秒）。DB claim SQLの10秒停止/遅い完了、件数上限、競合lease、失敗backoff/上限、遅いRPC、不正ack、executor精算競合を検証。独立Code/Security観点レビューに未解決所見なし（独立再実行なし）。全test process完了、今回実行中なし。ログprivate tmp: studiquo-recovery-focused.log / studiquo-recovery-final-full.log。実D1/VMは未検証。
- reaperは内部未接続。公開route/scheduler/binding設定なし。0010〜0013 remote未適用、token紛失/ローカル停止不明のclaimed自動解放とretentionは未実装。物理台帳削除/attempt巻戻しによる復旧はしない。rollbackは入口を閉じ台帳保持。
- 正常区切りに続いて独立Plannerで次の新Notebook採用を調査し、RAG_PDF_ADOPTION_DESIGN.mdへ設計のみ記録。次の実装は本文保存を増やさないmetadata/receipt/原子的registry移行＋合成状態試験。intake document IDとNotebook.ragDocumentIDを固定、trusted manifest/text hashをbind、registry INSERTのintake取消triggerを維持し移行後は文書/receipt guardへ切替。receiptとregistryの片側成功をDB内でabortする。既存LibrarySyncの通常prepareで別世代へ上書きしない受渡しも必要。
- 本文staging/転送方式は未確定。現在consumeResult終了時にmanifest参照を捨てるため、settle後の再取得はできない。通信中だけ保持（転送中の受付枠/期限/切断対応）か暗号化短期保管（保持/鍵/削除/認可/費用）が別設計境界。設計文書を実装済みとしない。iPad/公開送信は未接続。
- Linux環境の用意/指定質問は回答未受領。Docker/Podman導入を続行指示から推測しない。一方metadata unitなど独立作業は継続可能。Notion既存カードに着手/結果/残件を追記済み、状態進行中。keys/有料API/追加download/commit/push/deployなし、自動スケジュールPAUSED。Project差替え対象DATA_AND_MIGRATIONS/SECURITY_AND_PRIVACY/HYBRID_RAG、Desktop/upload未変更。

## 内部orchestrator・受付上限・実Docling接続（2026-10-18）

- ユーザー指示に従い正常な区切りでは止めず次unitへ。pdf-process.ts/pdf-manifest.js追加、jobにtoken付き実行guard、readerにcancel完了観測、intakeにserver policy必須のbounded登録を追加。公開route/config/bindingやiPad採用は未接続。
- header→reserve/receiveclaim→有限reader/digest→dispatch1回→private parse→strict structure→非公開trusted consumer→停止確認精算→最終小状態再認可。consumerはstaging専用で参照を解放し、正式採用は別guard/commitが必須。結果manifestを直接返さない。
- 独立reviewで未完了verifyによる早期slot解放High、cleanup期限再作成Medium、readerTask/manifest参照残存を修正。開始実taskを追跡し、不明なら枠保持。大結果/readerTask/Request参照は精算前に解放。consumer pendingも枠保持。最終Code/Security観点reviewに未解決所見なし（独立再テストなし）。
- 全サーバー1,812/処理17/intake24成功、差分確認成功。最初の一時shadowingテスト失敗は修正済み。新MCP→実DoclingJob(Node shim)→実loopback HTTP→実offline Doclingの合成2pageを確認、parsePOST1回/7.642秒/非公開testconsumer/job精算/一時領域削除/helper停止。通常sandbox listener権限失敗後、127.0.0.1限定・許可されたlocal試験で成功。VM lifecycleはmockで実OS隔離ではない。本文/manifestはrepo/Notionへ保存せず、docs/RAG_PDF_ORCHESTRATION_REPORT.md/RESULTS.jsonへmetadata記録。
- 次の計画Step3実Linux/Cloudflare VM確認に必要なDocker/PodmanがこのMacにない。実行環境の用意/指定が必要。実基盤未確認のままStep3完了/公開とはしない。続く残件: 実binding/D1、停止不明/token紛失復旧・監視/reaper/retention、heap/実費policy校正、公開rate limit、result staging→新Notebook採用/iPad。
- 今回起動した全test/helperは完了・停止確認済み、実行中なし。keys/新有料API/追加モデル/commit/push/deploy/remote migrationなし、0010〜0012未適用、自動スケジュールPAUSED維持。
- Notionは着手/結果/次の一手を更新済み、実Linux環境の用意/指定をあなた待ち。非同期質問で「このMacにDocker環境を用意する/利用できるLinuxを指定」を提示中。回答は未受領、通常判断や公開操作の許可を推測しない。Project差し替え対象DATA_AND_MIGRATIONS/SECURITY_AND_PRIVACY/HYBRID_RAG、Desktop/upload未変更。

## Step1〜2のjob/admission基盤（2026-10-18）

- 計画通りの継続指示でfull High/独立Planner・Code・Security観点レビュー。新0012_rag_pdf_jobs.sql、rag/pdf-jobs.ts、専用testを追加。intake一意job、owner/global active/memory/day件数/unitsを単一SQLで予約。server policy必須、64MiB/件の保守的weight（heap実測保証なし）、UTC日窓、保存済み予約/精算値で計算。
- reserve retryはID/stateのみ、receive claim勝者だけexecution token（DBはhash）、同token dispatch CAS一度/ever_dispatched不可逆。intake取消/差替え/失効→stop_requested、期限も停止要求のみ。未停止active枠は窓を越えても保持。未claimはstop後0でclose、claim済みはtrusted executor token＋実停止確認で精算（未dispatch0/dispatch済みfullreserve）、再精算冪等。既存AI credits/実請求は変更なし。
- job17＋既存PDF52=関連69test成功、独立review残指摘なし。サーバー全体回帰1,792件成功（失敗/skip 0）。今回テストprocessは全て完了、実行中なし。独立再テストなし。実D1・実VM・heap測定は未実施。0010/0011/0012すべてremote未適用。
- 次はこの状態機械を使う有限受信/verify/明示cancelの内部orchestratorと実停止契約の接続。公開前にintake予約API自体の行数/rate上限、reaper/cleanup retry、停止不明/token紛失の証拠付き復旧、retention、memory/実費policy校正が必要。今回をStep1/2全体完成としない。Docling実dispatch/iPad/採用は続く工程。
- 本文/原PDF/原digest/タイトル/生tokenをjob台帳へ保存せず、固定error。policy/stopConfirmedをclientから作らない。token紛失・DB障害は枠保持で閉じる。keys/有料API/commit/push/deploy/自動スケジュール再開なし、既存dirty保持。
- Notion既存カードへ着手/結果/次の一手を更新済み。Project差し替え対象: DATA_AND_MIGRATIONS.md、SECURITY_AND_PRIVACY.md、HYBRID_RAG.md。Desktop置き場/upload未変更。

## 今後の本体ロードマップを整理（2026-10-18、計画のみ）

- ユーザー依頼でRAG_REMAINING_IMPLEMENTATION_PLAN.mdに現行9段階と各完了基準を追加、過去計画は履歴として保持。独立Plannerの順序確認を反映。今回はコード/設定/モデル/課金変更なし、テスト再実行なし。直近1,775成功は前工程の結果。
- 順序: 評価基準を最初に固定→1受付枠/並列メモリ/費用予約/once-only claim→2取消削除/停止/lease/retention→3実Linux基盤とprivate Docling接続→4iPad/結果採用/構造索引→5初回総合試験→6意味分割/抽出改善→7検索rewrite/rerank比較→8回答漏れ/補足境界/限定validator→9最終総合試験と限定公開。1〜2は一体設計、Linux準備は並行可能。停止不明の枠解放/再送を禁止する設計を先に決める。
- 友人の固定contextでのprompt候補作業は今から並行可。本体検索が安定してから統合再評価。本番v1/凍結評価/未使用20問を維持、全変更同時比較をしない。OCR/図/数式・精密bbox・RAG利用エージェントは能力別の追加段階。
- 次のコード作業は従来どおりStep1〜2のadmission/job状態遷移設計。今回は計画を公開/新有料評価の許可と扱わず、自動スケジュールPAUSED維持。今回実行processなし。Notion既存カードへ計画の着手・結果を追記済み。
- 今回のProject複製の追加更新: なし（RAG計画/引き継ぎだけ）。前工程DATA_AND_MIGRATIONS/SECURITY_AND_PRIVACY/HYBRID_RAGの差し替え必要記録は保持。置き場変更なし。

## 新規PDFのintake予約・bytes同一性を実装（2026-10-18）

- 前工程に続きfull手順/独立Planner・Code・Security観点レビューを実施。新0011_rag_pdf_intakes.sql、rag/pdf-intake.ts、専用testを追加。text hash前の新規Notebook用に別intake owner/doc/current generation/server UUID/request/rawSHA256/bytes長/両同意epoch/10分期限を保存し、本文・PDF・タイトルは保存しない。
- prepare CASと厳密current request retry（期限延長なし）、flags offでも取消、単一SQL再認可とbytes copy/長さ/signature/実SHA256/再認可を実装。既存rag_documentsは予約できず、同table変更やraw同意・account失効でpendingを取り消しdigest/長さを消す。intake世代はtext文書世代とは別。行を破棄して世代を巻き戻さない。
- 関連52test成功（intake21＋認可18＋preflight13）。独立reviewに未解決所見なし。全体回帰1,775件成功（失敗/skip 0）。今回テストprocessは全て完了、実行中なし。実D1のtrigger連鎖/競合・実PDF/実iPadは未検証。
- reader接続を含めず、verifierは有限readerの後だけを想定。admission未完成なのでbody reader/公開route/Doclingへ未接続。snapshotはlease/費用予約/once-only claimではなく同時verify成功を防がない。過去全request ID履歴は保存せず元期待世代の再送拒否を保証。TTLは自動DB物理消去ではない。
- 次は受信前の受付数/並列メモリ・費用の予約と一度限りjob claim、job取消/削除・送信/採用前再認可。以降にDocling dispatchと新Notebookへの採用/iPad接続。intakeをtext registryへ安全に対応付ける必要がある。retention/受付上限は公開前必須残件。
- 0010/0011はremote未適用。keys/有料API/commit/push/deploy/自動スケジュール再開なし、既存dirty保持。Notion既存RAGカードへ着手・結果・次の一手を更新済み、進行中を維持。
- Project資料差し替え対象: DATA_AND_MIGRATIONS.md、SECURITY_AND_PRIVACY.md、HYBRID_RAG.md。置き場やclaude.ai uploadは未実施。

## 原PDFの永続同意・文書認可を実装（2026-10-18）

- 前回の次工程をfull手順で継続し、独立Planner/Code/Securityレビューを実施。0010_rag_raw_pdf_consent.sqlとrag/pdf-authorization.ts、専用テストを追加。認証済みsession.subからcanonical ownerを計算、raw同意のCAS epochと親RAG epochへのbind、既存登録文書のsource ID/generation/text hash/両同意epochを単一SQLで確認する。
- RAG同意変更/削除とaccount tombstoneのtriggerにより、旧Worker経由でもraw同意を原子的に無効化する。削除の途中失敗→再開や同意ABAで復活させない。safe integer最大epochは再付与不可、失効は可能。raw撤回で既存text RAGや索引は消さない。任意owner入力は拒否、payload/proofは非同期処理前コピー、DB例外は固定エラーにする。
- 対象30件成功、Security独立18件成功、独立レビュー未解決指摘なし。全サーバー回帰1,752件成功（失敗/skip 0）。全体runの開始後に追加した2件は最終対象30件の方で成功、実装コードは同一。今回テストprocessは全て完了、実行中なし。実D1の競合/trigger運用は未確認。新0010はファイルとローカルSQLiteのみでremote適用なし。
- このguardは既存registered文書に対するSQL時点snapshotのみ。新規Notebookでは解析前のtext sourceHashがないので、そのまま接続不可。次は新規intake文書/generation/rawPDF digestの予約と同一性確認、admission/費用予約/job取消削除、送信/採用前再認可の順で設計・実装する。公開routes/binding/iPad/Docling実送信は未接続、JWT検証は将来の呼出元で既存realSessionを使う。
- 既存dirtyは保持、キー読取/有料API/commit/push/deploy/migration適用なし、スケジュールPAUSED。Notion既存RAGカードへ着手・結果・次の一手を更新済み、進行中を維持。
- Projectの資料はDATA_AND_MIGRATIONS.md、SECURITY_AND_PRIVACY.md、HYBRID_RAG.mdの複製差し替えが必要。Desktop置き場/claude.aiアップロードは未実施。

## 原PDF受信の前処理を実装（2026-10-18）

- 友人のOpenAI追加はメール返信待ちで保留。ユーザー担当のRAG本体へ戻り、full手順で独立Planner/Code/Security確認を実施。
- ai-privacy.jsからヘッダー専用判定を抽出し、既存JSON/model/取消削除の挙動を保持。新規rag/pdf-preflight.jsはflag/AI年齢・同意/RAG同意/別rawPDF同意と形式を本文取得前に確認。10MiB・10秒・65,536 read操作・PDF signature・宣言長一致、abort/失敗/cancelを扱う。共通未解決Promiseへのreaction累積をreviewで修正し現在read一件のみ保持。
- 新primitiveは未接続。公開route/binding/config/DB/アプリ/Docling送信なし。ヘッダーは自己申告で認可ではない。次は本人・文書generation・永続rawPDF consent epoch・admission/費用予約/取消削除を接続前に実装する。最大約20MiB/呼出しのbuffer＋返却コピーと並列制限も考慮する。
- 対象23件成功、Security独立23件成功、最終Code/Security未解決所見なし。最終サーバー全体1,736件成功（失敗/skip 0）。今回起動したテストprocessは全て完了、実行中なし。実Workers受信/切断、Linux/実VM、実資料精度は未検証。テスト成功を回答品質改善とみなさない。
- コミット/push/deploy/migration/有料API/キー読取なし。スケジュールPAUSED維持、既存dirty保持。Projectの資料の今回追加更新: なし（未接続の内部部品とRAG設計記録）。Notionは既存RAGカードへ着手・結果を追記し、進行中を維持して次の一手を更新済み。

## 評価用キーの共同利用準備（2026-10-18）

- ユーザーは今の評価用キーを友人の担当にも使うことを依頼。OpenAI Docsの公式model/権限/spend limitを確認。元キーを使う秘密共有か同じ評価projectの友人専用キーか、共有経路を非同期質問中。秘密値は読取・表示・複製していない。友人のPCやOpenAI権限を設定済みとしない。
- collaboration/rag-prompt/API_ACCESS.mdへ共有手順と予算提案。Luna通常入力$0.10/出力$0.50 per million。入力20k/出力8192仮定で24calls約$0.15、72calls約$0.44、360calls約$2.20。初回run$1/友人月$5は未承認の提案。USD管理で実為替価格とは混同しない。
- 現kitはofflineのみ。API実行adapter/予算予約/取消再開の独立確認と実疎通は未実施。有料API0回、既存キー/本番/課金Dashboard変更なし。共有キーでは友人だけの費用上限・利用者別追跡を保証できない。hard limitとalertの違い、project上限があなた側の評価にも影響する点を明記。
- 次の一手は共有経路の回答、友人側の秘密設定、実行adapter/予算承認。今回の資料は未commit/push。追加のProject複製更新はなし。実行中のAPI評価processなし。Notionの友人タスクへ準備と未完を追記する。

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
node --test services/docling-worker/index.test.ts
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
