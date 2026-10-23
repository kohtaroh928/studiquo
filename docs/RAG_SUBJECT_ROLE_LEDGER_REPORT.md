# 対象role paired比較：offline manifestと最初の段階のreplay

2026-10-16。[比較設計](RAG_SUBJECT_ROLE_PAIRED_DESIGN.md)の保存基盤に先立つ、小さい検証単位。比較評価全体の完成ではない。

## 実装した範囲

`subject-role-paired-ledger.mjs`に固定12pair/24jobのmanifestと、NDJSON文字列を検証して状態を再計算するreplayを追加した。偶数問はbaseline→candidate、奇数問は逆順。ordinal/pairIndex/index/variant/stage/questionHash/requestHashを照合する。全4段階の上限は2/6/8/8送信、予約合計196608microUSDで固定する。予約は実費・請求上限ではない。

今回は**stage0の2jobだけ**を受理する。`transportAttached:false`・`persistenceAttached:false`・`reviewGateAttached:false`・`maxExecutableStage:0`をmanifestへ明記した。旧8問runや将来のpaid manifestとは別suite。ファイルへの書込、lock、fsync、packet生成、review受付、API送信、鍵読取、CLIはない。依存sourceの読取とhash計算だけを行う。後続の保存処理・review gate・transportが完成するまで実評価に使用しない。

予約前後の順序、重複terminal、余剰field、改変、上限超過、異常diagnosticを固定errorで拒否する。保存候補のplan/usageを既存parserで再検証し、原質問からprovenanceを再生成する。responseHashは形式だけを確認でき、元raw responseとの一致や上流実行を証明しない。hashchainも本人認証ではない。秘密反射guardは後続transportで接続するため、このmoduleだけで任意本文を安全に永続化できるとは扱わない。

## 状態の区別

- 片方だけ完了したpairをpartialPairsへ保持し、comparablePairsへ加えない。
- 予約のみ/途中pairはsafeReopenCheckpoint=false。nextJobは継続中のメモリ内処理の順序だけを示すもので、ディスクrunの再開許可ではない。
- 最初の2完了+stage_finishedはreview待ち。形式完了してもcomparablePairs=0、意味pending・根拠unknown・releaseAccepted=false。
- どちらのarmでも技術失敗があればstopし、予約を保持する。後続eventも拒否する。
- 予約済みpair数と未予約pair数を予約記録から数える。最初のarmが予約のみ・0完了の失敗でもそのpairは未予約へ戻さない。予約は実送信の証明ではないため「未送信数」と呼ばない。
- 未実装のpackets_ready/review/continueを拒否し、review文字列を追加するだけでstage1へ進めない。

## 検証・残件

対象12テスト：全24jobの順序/上限/各bodyhash、clone、初期・予約・partial・review待ち、両armの失敗、取り違え・旧manifest・改変、usage/provenance再検証、形式合格の意味pending、無効なreview/重複terminal、固定error、byte/truncationを確認。oracleを使うplanは合成mockであり、モデルの精度評価ではない。

次はprivate file/共通lock/O_EXCL/file→directory→journal fsyncを伴う保存処理を実装する。その後、中立packet/mapping・元review artifactと全先行stageの再評価を追加し、初めてstage1以降の遷移を許す。さらにbounded transport・3箇所secret guard・独立安全確認後に新しいpaid manifestを固定する。今回のoffline台帳をpaid runへ転用しない。

追加API/鍵読取0。本番prompt v1、未使用20問、旧5runの停止状態は変更しない。新moduleを呼ばないことでrollbackでき、アプリ/DB/Worker runtimeへ影響しない。

最終検証：対象12・全Worker1,568成功（失敗/skip 0）。独立コード12・安全12成功、未解決High/Mediumなし。予約済みpairを0完了時に未着手扱いするMediumを修正し、予約のみ/両arm失敗の回帰で確認した。旧候補source hash・最終停止journal hash・計5runのlock保持を再確認。詳細は [結果JSON](RAG_SUBJECT_ROLE_LEDGER_RESULTS.json)。Projectの資料の更新: なし。
