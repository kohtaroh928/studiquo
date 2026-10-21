# 原PDF停止再試行と復旧

2026-10-18。High変更の内部部品。`rag/pdf-job-recovery.js`、追加migration0013。公開route、scheduler、配備設定へ未接続。

## 目的と受け入れ条件

通信断やexecutor終了で残った期限切れjobを再停止し、止まったか不明な処理を可視化する。重複解析を始めず、停止不明の受付枠や利用量予約を勝手に解放しない。

- 一回のpassは各DB段階最大10件、停止RPC候補最大10件、直列、最大10秒。停止RPCは最大2秒待機、reaper leaseは30秒。DB応答待ちもpass期限に含める。
- 期限切れはまずstop_requested。未claim（token_hashなし・ever_dispatched=0）の停止要求だけ、同一UPDATE条件でsettled/0へ。claimとの競合でも受信済み枠を解放しない。
- claimedの停止試行はCAS勝者だけ。RPC前にattemptを加算、失敗後10秒/30秒のbackoff、合計最大3回。最終試行途中に落ちてもlease満了後にneeds_attentionとなり、4回目を送らない。
- 固定契約`{cancelled:true}`だけremote_stopped。**VMの停止はローカルreader/verifier/consumerの終了を証明しない**。claimedの枠/予約unitsは保持する。元executorが実taskとVM停止を確認してtoken付きsettleした場合だけ通常精算し、次のpassで台帳をdoneへ。
- 古いRPC応答・古いleaseが新しいleaseを上書きしない。timeout後の実RPCの結果は観測するが、遅い結果から台帳更新や精算を再開しない。
- parser呼出しは常に0。本文、原digest、owner、execution token、生例外を新台帳・返却・ログに保存しない。

## 永続化と互換性

0013は0012の後に適用する追加tableのみ。job ID、attempt数、期限付きlease、固定outcome、remote確認時刻を保持。初期化・候補選択・更新は全て件数上限付き。既存job/APIの状態や精算規則を変えない。flags off、同意撤回、account削除後も内部停止は可能。DB障害は固定errorで閉じ、枠を維持する。

`recoverRawPDFJobs`と集計`rawPDFRecoveryStatus`はtrusted operator専用。クライアント引数、一般公開API、未認証監視へそのまま接続しない。監視はheldClaimed/remoteStopped/needsAttention/leased/oldestOverdueMsだけを返す。remoteStoppedも受付枠は保留中であり、自動復旧完了の意味ではない。

## 障害対応

1. 新規受付を停止し、原PDFを再送・再解析しない。必要なら既存の処理flagを止めるが、cleanup用bindingは維持する。
2. 集計で保持中・停止失敗・leaseを確認する。停止処理の試行は固定上限内だけで行う。timeoutは実RPCのキャンセルを意味しない。
3. 元executorが動作中なら、そのreader/verify/consumer/RPC終了とVM破棄を確認して既存token付き精算へ進む。
4. token紛失・元executor消失・停止証拠不足ではclaimed枠を保持する。単なる管理者booleanやTTLだけで解放するAPIはない。信頼できるローカル停止証拠による復旧契約は別の未実装項目。
5. attempts上限を手動で巻き戻さない。必要な再試行・復旧は事実確認と別レビューを経る。

ロールバックは呼出しを止め、台帳を残す。公開接続前なので現時点で稼働設定の変更はない。job/recovery/intake tombstoneの物理削除は実装しない。jobの一意記録を消すと同intakeの再解析や利用量回避を許すため、保存期間・削除要求・日窓会計・再実行防止を満たすretention設計が必要。

## 検証と残件

SQLiteによる期限/競合/再試行上限/不正ack/遅い応答/精算競合/DB失敗を検証する。実D1の競合、実Cloudflare RPC/VM、scheduler、通知、ローカル停止証拠によるclaimed自動回収、retentionは未検証または未実装。回帰テスト成功は回答精度改善の証拠ではない。

実装で参照したD1契約: [prepared statements](https://developers.cloudflare.com/d1/worker-api/prepared-statements/)。単一SQLの条件付き書込みとmeta.changesで勝者を判定し、read後の状態を信頼して無条件更新しない。


<!-- Historical dae6129 checkpoint; JS references are historical. -->
4. token紛失・元executor消失・停止証拠不足ではclaimed枠を保持する。単なる管理者booleanやTTLだけで解放するAPIはない。Step6-Aに停止証拠基盤を追加したが、このreaperへの接続はStep6-Bの未実装項目。


## Step6-A追加（2026-10-19）

[停止証拠の基盤](RAG_PDF_STOP_EVIDENCE_DESIGN.md)を追加。新protocolの元executorがlocal証拠を保存済みで、remote証拠も揃えばtokenなし精算できる。既存process/reaperは未接続で、この文書の現行legacy挙動は維持する。証拠なしのexecutor消失は引き続き保留。0016適用時の旧purge閉鎖と、その再開に必要な原子的保存期間契約もBで扱う。


## Step6-B接続済み（2026-10-19）

新protocolの実processorが保存した両証拠に限り、reaperがtokenなし精算する。候補最大10件、既存attempt/lease/backoffとpass期限を維持し、精算SQLでliveleaseを再検査。旧remote_stopped journalを証拠に置換しない。証拠保存前のexecutor消失/legacyは保持する。0017が証拠childと親の原子的保存期間整理を追加し、旧purge契約をv2へ更新（enabledは0へ）。HTTP/cron/configは未有効、実Docling/remote検証は残る。詳細と今回検証は[Step6-B報告](RAG_PDF_STOP_INTEGRATION_REPORT.md)。


## Step5-Cのowner専用再試行（2026-10-20）

account削除専用の内部入口はserver-derived hashを必須にし、各DB候補/更新を対象ownerへ限定する。PDF pendingの間も他phaseは進め、独立phase完了後の再試行はPDFのみ。schema/bindingなしやremote ack単独でclaimed枠を戻さない。最小checkpointと旧完了記録の移行は[Step5-C報告](RAG_PDF_ACCOUNT_CLEANUP_REPORT.md)を参照。


## Step5-D2a v2接続（2026-10-20）

取消RPCの選択をpdf-rpc.jsへ集約。保存rpc_version=2ならflag OFFでもcancelV2(jobId,rpc_not_after)、legacy行をv2-only側で停止するときは保存deadlineでcancelV2を使用する。intake digest不要、期限の再生成/DBへのbackfill/失敗時旧cancel fallbackなし。復旧・account削除も同じ入口を使用し、remote ackだけでは枠を解放しない。旧schemaのlegacy cleanupは維持、新規v2受付は0018が必要。

詳細: [接続検証](RAG_PDF_RPC_V2_INTEGRATION_REPORT.md)。
