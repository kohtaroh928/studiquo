# 固定8問の元案/候補を比較する有限実行

2026-10-15。High（外部AI送信・利用量/secret・途中再開）。目的は独立値の結合/条件role未達を、過分割負例も含む同一問題で比較すること。既存6問のmodule/hash/実結果、runtime v1、bank/未使用20問は変更しない。

## 設計・受入条件

- 固定16requestのみ。質問index順、各対の順は偶数baseline→candidate/奇数逆。stageは6+6+4、同じprivate manifest/ledgerだけで継続する。
- manifestへ全16jobのordinal/index/variant/stage/request hash、source hash、制限を固定。毎回同じ版であることを照合し、任意selector/本文/modelを受けない。
- 予約は送信前に各8192microUSDをfsync、累計131072microUSD以内。失敗時も返さない。Luna公式料金input0.10/cache-write0.125/output0.50USD/百万tokenを2026-10-15再確認。この保守的予約と確定請求を区別する。
- 新規/既存runともowner/private mode/no symlink/no hardlink/dev-inodeを検証。running.lockを排他的作成。送信/保存/途中停止の例外時はlockを残し、再開・再送を自動で行わない。
- replayはchain/manifestとreserve→completeの順序、job/hash/plan/usage/stage境界を検証。確実なstage_finishedを持つ完了stageだけ継続し、failed/pending/途中行/partial stage/不一致なら停止する。
- 各送信60秒・stage360秒、予約fsync後に残時間再確認、本文読取までtimeout/cancel、request24KiB/response256KiB、endpoint固定/redirect:error/secret反射拒否。進捗通知とterminal保存を分離する。
- completed保存が不確実なら二つ目のterminalで上書きせずlockを保持。正常stage終了はstage_finished fsync→close→lock解除とdirectory同期。close/解除失敗も固定エラーにする。
- 出力planは合成資料だけでもprivate journalへ留め、本文/キー/上流errorを共有ログへ出さない。RESULTS/Notionはhash/件数/usage/評価IDだけ。requestHashは期待bindingで、上流の暗号学的証明ではない。

## 障害・悪用・撤回

同時起動、古いlock、tail破損、偽完了、権限/リンク差替え、manifest変更、予約/結果fsync失敗、HTTP拒否、本文停止、後から到着するfetch、秘密反射、過大usageをmockで検証。ひとつでも不明なら後続stageを止め、別directoryを作って送信し直さない。run全体の固定pathを運用で守り、アカウント全体のglobal budgetを保証したとはしない。秘密は引数のメモリだけ、既存loaderで実行直前に読み表示しない。

今回の新moduleを使わなければ評価停止でき、本番API/DB/アプリのrollbackは不要。既存テスト/独立コード・安全レビュー通過後にだけ固定runを開始する。コードの成功/形式の成功と、モデルの要求網羅性を区別する。実内容は別oracleと独立意味レビュー、人間goldはpending。結果と残件は完了後追記する。

参照: [Luna公式仕様と料金](https://developers.openai.com/api/docs/models/gpt-6-luna)。Projectの資料の更新: なし。

## 実装と障害試験

新`paired-task-planner-live.mjs`だけへ有限比較を追加し、旧6問moduleのsource hashは保持。12対象/関連23テストで固定順・6/12/16境界・16完了後0送信、正しいchainでも不正plan/usage/hash/variant/stage/予約額を拒否、tail/lock/mode/hardlink/symlink、同時実行、予約/結果/stage終了のfsync失敗、通知失敗、予約後deadline超過、本文停止/過大/遅延headers/秘密反射を確認した。

closeやlock解除/解除後directory fsyncの失敗も固定エラーで停止する。解除同期失敗ではlock再作成を試みるがbest effortであり、「必ず永続lockが残る」とは保証しない。呼出が失敗した場合は、見えるstage_finishedやlock有無だけで自動再開せず監査する。OS障害後までの完全排他・別directoryを含むglobal budgetを保証しない。

独立安全レビューは実装moduleにHigh/Mediumなし、対象11件成功。追加のcleanup障害試験は親側で成功し、最終コードレビュー/全Worker結果は完了後追記する。まだキー読取/実API送信なし。

## 実行前gate

全Worker1,373成功（失敗/skip0）、独立コード12/独立安全11成功、未解決High/Mediumなし。追加cleanup障害も含む対象12・関連23成功。独立Lowのlock同期best effortの文書化を反映した。旧source hash/runtime v1/過去評価不変を確認。

実行pathを `/private/tmp/studiquo-rag-paired-planner-20261015-01` に固定し、6+6+4を同ledgerの再検証後に順次行う。料金は公式モデルページで再確認済み、予約0.131072USD。通信/形式の最初の失敗で全stage停止する。意味上の漏れ・結合・過分割は比較したい結果なので、成功へ書き換えたり再送したりせず保存し、独立意味レビューで扱う。安全違反が判明した場合は後続を停止する。内容失敗を無視して本番採用するという意味ではない。

まだ比較品質/新8問API互換は未確認。次の限定実行の結果を追記する。

## 限定実行の停止と診断不足

固定runは最初のordinal0/index0/baselineでmanifest→reserved→failedの3行を残して停止。completed0、後続15件未送信、running.lock保持。chain/private0600を監査し、同run・別pathの再送を行っていない。送信試行は1件だが、provider受信/生成/課金の有無を確認できる記録はない。usage/確定費用は不明、予約は1件8192microUSD（0.008192USD）を残す。8問の比較結果や改善率は得られていない。

元runnerはfailedをdispatch_failed_or_uncertainだけにまとめており、通信/HTTP/本文/形式のどこで失敗したかを遡って特定できない。これをLunaの能力不足、API障害、キー不正、timeoutのいずれかと断定しない。元runnerを`baselines/20261015-paired-first-attempt/paired-task-planner-live.mjs.txt`へbyte保存し、元manifest/source hash/journal hashをRESULTSへ保持した。

この不足への修正として、今後の失敗記録にphase（fetch/body/validation）、HTTP status（100〜599/null）、reason（固定分類/許可済みparserコード）だけを追加。raw response/上流error message/cause/キーを保存しない。既存failedの診断が回復したわけではなく、診断を試すための再送もしていない。HTTP429、JSON plan不正、秘密を含む例外、秘密反射、本文timeoutをmockで確認。対象13/関連24成功、独立安全13成功・High/Mediumなし。最終コードレビュー/全Workerは完了後追記する。

既存runは監査が必要な停止状態として保持する。診断を追加した版での再評価を自動承認済みと扱わず、既存失敗の追加証拠または再評価判断を整理してから扱う。今回の結果は「制限・停止機構は動作、実比較は未完了、根本原因は未特定」。本番v1/旧6結果/未使用20問は不変。Projectの資料の更新: なし。

## 最終確認と判断待ち

診断追加後の全Worker1,374成功（失敗/skip0）、対象13/関連24/独立コード13/独立安全13成功、High/Mediumなし。元3行journal hashとlock、退避sourceと元manifest hash一致、旧6問/本番v1不変を再確認した。これらは根本原因の解明や8問の品質合格ではない。

次の具体案は、診断版で第1段階だけ（同じ固定3対、最大6送信、予約最大49152microUSD=0.049152USD）を新しい明示承認runとして評価すること。現時点では実行していない。最初の送信結果/課金が不明で、既定の初失敗停止・不明送信の自動再送禁止に当たるためユーザー判断を求める。承認後も旧runを解除/再開せず保存し、新runが一度でも失敗したら後続を止め、診断コードだけを確認する。実請求額は保証しない。

本番有効化/デプロイ/DB/キー変更は行わない。Projectの資料の更新: なし。

## ユーザー指示後の診断版第1段階

再評価の質問に対する「次の作業に進んで」を受け、提示範囲だけを新固定path `/private/tmp/studiquo-rag-paired-planner-diagnostic-20261015-01` で実行。元案ordinal0が完了、候補ordinal1で停止した。2試行/1完了/1失敗、同stageの残り4件と後続stage10件は未送信。新旧両runのlockを保持し、再送/lock削除/別path作成を行っていない。

新しい診断ではcandidateがHTTP200、phase=validation、reason=task_planner_invalid_planと確認できた。parserの順序から、completed/envelope/model/usage範囲/plan JSON parseまで通り、元v2 validatorで拒否された所まで分かる。どの引用位置/id/field/root整合条件が違反したかは、元validatorが単一エラーで候補内容も非保存のため不明。これを通信失敗やAPIキー不正と扱わず、旧runも同じ原因だったと推定しない。

独立監査で5行chain、全job hash/source hash、slot binding、lockを確認。baseline index0は独立した2対象の値scopeと対象・属性対応を保持している。厳密注釈一致0はrequest spanが広い差で、意味精度0%ではない。candidateの改善/劣化や8問全体の品質は評価できない。人間goldはpending。

完了した1件のusage=input780/output448（内reasoning249）/total1228、待ち時間6.203秒。既知完了分のuncached試算は0.000302USD。失敗分のusage/請求額は不明なので全体費用をこの値や0としない。診断runの予約2×8192=16384microUSD（0.016384USD）は保持扱いで、実費とは異なる。旧runの予約8192microUSDも残る。

今回の再評価範囲は停止で終了。次は本文を保存しないまま、v2検証の違反種類を固定コードで区別するオフライン設計/検証を行う。追加APIは自動で反復しない。コード変更なしのため全Worker1,374成功・独立コード/安全13の直近結果を維持し、ログ監査を実施。Projectの資料の更新: なし。


## 個別違反を記録する診断追加（2026-10-15）

ユーザー「特定して」を受け、元v2 validatorを凍結したまま、拒否時だけ固定code/role/indexで分類する評価専用diagnosticを追加した。元の合否は変えず、offset数値・本文・任意field・上流message/causeを保存しない。旧paired response/live sourceは `mcp-server/scripts/rag-quality/baselines/20261015-before-granular-diagnostic/` に保存し、旧runとjournalとlockは保持する。診断は今後の拒否条件を観測する仕組みで、旧失敗の個別条件を復元するものではない。

新入口はindex0/candidate固定、最大1送信、新規directory限定（排他的mkdir）、8192microUSD先行予約、60秒以内、本文上限/キー反射排除/redirect禁止/失敗時lock保持を既存runnerと共有する。予約は実請求額ではない。mockでは分類、余剰field/不正型/順序、原validator拒否維持、送信前fsync障害、再実行拒否、selector拒否、秘密反射、timeout、transport errorの偽装診断不採用を確認した。

独立設計・コード・安全レビューでHigh/Mediumなし。関連17テスト独立成功（その後one-shot防御2テスト追加）。全Worker1,380成功・失敗/skip0、ログ `/private/tmp/studiquo-granular-all.log`。iOSは変更せず今回未実施。本番v1・旧6問・未使用20問を変更していない。rollbackは新診断入口の利用停止と退避版への復元で可能だが、過去journalを変更しない。

実確認は新path `/private/tmp/studiquo-rag-paired-candidate-identify-20261015-01` で最大1回のみ。再現しない場合も自動追加送信しない。結果は追記する。Projectの資料の更新: なし。


## 個別拒否条件の実確認（2026-10-15）

ユーザー「特定して」により固定候補index0を1回だけ確認。HTTP200/validation/task_planner_invalid_plan。固定診断 `span_quote_mismatch / subjects / taskIndex=0 / spanIndex=0` を取得した。最初のtaskの最初のsubjectについて、原文sliceと引用textが一致しなかった。bounds/text型を先に通過しているので、数値範囲外や空文字ではなく文字位置との一致違反。引用textとstart/endのどちらが誤りか、モデル内部理由、旧runも同じ原因だったかは、本文非保存のため断定できない。

新run /private/tmp/studiquo-rag-paired-candidate-identify-20261015-01 は3行/1予約/0完了/1失敗。hash bc316b31f7860a3b8de415092b30f79380bdfbe53b70b70503657d59091a9bf1。8192microUSDを予約として保持（実請求・失敗usageは不明）、lock保持、自動再送なし。後続14件は引き続き未送信。本番v1/旧結果/未使用20問は不変。次は質問の原文位置をモデルが計数する部分の設計見直し（原文引用からサーバーが位置を決定する案等）。検証を緩めたり不一致を黙って補正したりしない。独立監査結果を後記する。Projectの資料の更新: なし。

独立監査完了：新journal SHA/chain/source hashes/固定candidate0/予約先行/1試行/旧2runを含むlock保持を確認。今回の拒否条件は原文位置とsubject引用の不一致。textとoffsetのどちらが誤りか、モデル内部理由、旧run同一原因、失敗usage/実費は不明。再送せず原因調査を終了した。
