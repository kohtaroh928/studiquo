# 原PDFの処理済み台帳整理：Step5-B

2026-10-19。High/full。既存`codex/rag-wip`上でローカル実装と合成metadata試験。remote適用・実ユーザーデータの削除・公開/cron有効化はしていない。

## 実装と守る条件

追加0015は0010〜0014を書き換えず、jobへwriter_version、purge control・候補用index/view・削除guardを追加する。既存行はlegacyのまま保持し、新reserveだけschemaがあればfloor-v2を明示する。旧schemaでの停止/精算は維持。

削除には、state=settled、created_at/settled_at既知かつ順序正常、精算から暫定48時間以上、過去UTC日窓、同owner/documentのintakeが永続cancelledまたは別UUIDの新世代へ置換済みであることが必要。intake不在は保持。registryに文書があれば削除済みstateでも保持する。recoveryがあればdoneかつlease完全解除のみ。remote_stopped/needs_attention/未精算/未知時刻/legacyは保持する。48hは内部運用案であり公開保証値ではない。

内部入口は`RAG_PDF_RETENTION_ENABLED`と`RAG_PDF_JOB_PURGE_ENABLED`の両方が文字列true、DB enabled=1、既知schema/契約が必要。configにflagは追加せず、DB enabled初期0、HTTP/cron未接続。0014 physical_purge_enabled=0は旧工程の制御として維持し、0015だけで別管理する。Aの集計は新flag/controlも認識する。

## 一回の処理と原子性

[D1 batchのtransaction仕様](https://developers.cloudflare.com/d1/worker-api/d1-database/#batch)に従い、4statementを一transactionとして実行する。

1. 固定契約/DBclock/schemaを再確認し、期限付きleaseと単調writer fenceを取得。
2. partial indexの時刻＋jobキーcursorで**粗い候補を最大10件だけMATERIALIZED**し、次cursorと件数を確定。ここではintake/recovery/registryの高コスト照合をまだしない。
3. そのcursor範囲内だけを再認可して親jobをDELETE。BEFORE DELETE triggerが全条件を再確認し、admission floorをMAX(old, deleted window+1day)へ進め、done/unleased recovery childを削除する。
4. cursorを進め、leaseを解除。粗い候補が空ならcursorを0へ戻し、次回に保持対象を再確認する。

ABORT/制約/child/parent/解除失敗では、先行job削除・floor・child・cursor・lease・writer fenceも全rollbackする。JSの事後changes確認を原子性の代用にしない。RETURNING定数の結果件数だけ返し、job/owner/token/本文を返さない。候補cursorには最終照合キー1組を保持するが、公開応答・監視ログへ出さない。

全待機は10秒まで。DB statement自体はtimeoutで取消できず、commit不明時に自動再送しない。leaseのDB再検査で期限後に削除を開始させない。秒精度DBclockは**次秒へ切り上げて**leaseを保守的に判定し、短すぎるleaseは拒否する。走査は単なるeligible後LIMITではなく粗いindex範囲10件を先に確定し、大量の保持対象でも次passへ進める。

## 互換・時計・将来の正式採用

最初に成功したpassでwriter_fencedが1になると、purgeを無効化してもlegacy writerのINSERTをDBで拒否する。旧窓INSERTは0014のfloorが拒否する。既存jobのID/owner/intake/generation/window/writer版の移動も禁止。既存legacy jobを自動で新版へ書き換えない。

DBclockが前回から後退、24時間超の間隔/跳躍、callerとの5秒超の差なら削除を拒否する。長期停止後の再開には独立した運用確認によるclock再設定が必要で、今回の入口は自動リセットしない。lease期限は初回に観測したDB時刻＋monotonic残時間とcaller deadlineの小さい方を採用し、許容された正方向caller skewで延長しない。monotonicな待機期限とDB leaseを併用し、DB時刻そのものが壊れていれば安全を証明できないため受付停止/調査へ回す。

契約はpre-adoption-v1のみ。未知rag_pdf_* table/receipt tableがあれば閉じる。**将来のreceipt/採用migrationは、参照を書き始める前にcontract_versionを変更して旧purgeを閉じることが必須**。table名検出だけを将来互換の保証にしない。receipt自体の保持、account削除phase、DO tombstoneの有限削除は実装対象外。

## 検証

最終server **1888 pass / 0 fail / 0 skip**。新purge23件、A retention14件、Wrangler splitterによる0001〜0015回帰を含む。48h境界/未知・最近精算/当日/legacy/全未精算状態/復旧lease/registry/欠落intake、旧writer/floor/identity、clock後退・跳躍・同秒内短lease、遅延batchとtransaction途中の契約/receipt/lease変更を検証した。

child/parent/後続candidate/lease解除の障害注入で全rollback、当日COUNT/unitsと未精算memory不変を確認。10000件の保持backlogでも粗い候補10件とcursor進行、保持10件の後の適格jobへ到達することを確認。EXPLAINでcoarse partial indexと削除guardのjob PK lookupを確認。

実local workerd/D1では15migration、defaultdisabled、同時2passで計3jobの一度だけの整理、floor前進、done child削除、parent失敗によるchild/parent/floor/lease rollback、未知receipt契約の拒否を確認。再現はmcp-serverから`node tools/rag-pdf-purge-local-smoke.mjs`。127.0.0.1の権限で実行し、外部bindingなし・一時D1は終了時破棄。SQLite単体結果をremote D1の実運用成功とは説明しない。

独立Planner/Code/Securityを使用。レビューで判明したeligible後LIMITの走査漏れを粗い候補＋cursorへ修正し、leaseの同秒内超過をDB次秒判定へ修正。さらに監視の有効表示が共通flagを見ないLowを修正し、両flagを個別に無効化する回帰を追加。Code/Securityの最終再レビューで残所見なし。reviewer自身の独立テスト再実行はない。

## 有効化・rollback・次の一手

有効化は今回行わない。配備前にbackup/復旧点、staging別系統更新、license/OS CVE、clock再確認と監視/予算、0015適用とwriter版照合が必要。停止時はpurge flag/DB enabledを閉じ、0015/writer fence/floor/intake失効を残す。物理削除開始後に旧writerへrollbackしない。旧backupのactive状態をそのまま再開しない。

Step5-A/Bのローカル実装はできたが、account PDF pending/DO有限保持/receiptと自動運用は未完。次はStep6の停止不明claimed/executor token紛失の証拠付き復旧を設計・実装し、その契約に合わせてStep5-Cのaccount削除phaseを接続する。Bを全retention/公開完了としない。

今回7ソースのhashを同伴RESULTSへ記録。過去Step1/Step5-Aのhash記録は歴史的な版として保持し、現在版へ上書きしない。機能テスト成功は回答精度の改善を意味しない。commit/push/deploy/有料AI/モデル変更なし、automation PAUSED。

Project資料更新対象: DATA_AND_MIGRATIONS、SECURITY_AND_PRIVACY、HYBRID_RAG。配布用複製/upload未変更、既存リリース00_残タスク表の配備前残件も保持。
