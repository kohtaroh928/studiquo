# 原PDF処理の保存期間・整理順（Step 4）

2026-10-19。Highデータ削除設計。**設計のみ、実装/DB削除/配備なし**。独立Plannerによる実コード調査を反映。Step5はこの設計の最小単位を実装し、Step6の停止証拠付き復旧や将来receipt/期限付きRPCと混同しない。

## 目的・スコープ・受け入れ条件

不要な解析metadataを減らしつつ、遅い要求による再解析・削除文書の復活・日次制限の回避・停止不明の処理を見失うことを防ぐ。今回は0010〜0013、pdf-intake/jobs/job-recovery、private DoclingJob、account削除、将来receiptの保存契約を扱う。本文保存先や公開API、課金、同意内容は増やさない。

受け入れ条件は、現UTC日窓の件数/unitsと全未精算枠が整理前後で変化せず、期限切れ要求・古い世代が復活せず、停止/削除の残件を追跡できること。保持期間は法令由来の値ではなく初期運用案。公開時のプライバシー説明/予算/運用条件と一致させてから有効化する。

## 現状から分かった境界

- 原PDFの受付有効期限は10分、jobは最長3分かつintake期限まで、有限reader10秒、private処理125秒/破棄待機10秒、結果転送30秒。期限は停止確認やデータ物理消去とは別。
- `rag_pdf_jobs`の同UTC窓のCOUNTとSUMがadmission条件。0精算でもCOUNTへ加算される。当日のsettled行を消すと回数制限を迂回できる。
- intakeは(account,document)ごとの現在世代とUUIDを保持。消すとexpectedGeneration=0で古いdocument IDを新規として扱える。UUIDがランダムなだけでは遅延した既知要求を防げない。
- 現jobはsettled_atを持たない。deadlineは精算時刻ではなく、古いjobが今日精算される場合もある。期限を48時間保持の起算点に使わない。
- private DOはstorageが空なら同job IDでもclaimできる。最終状態の一律deleteAllは再実行防止を壊す。
- `deleteAccountRAG`は既存text/vectorの終了を確認するがPDF claimed job停止は待たない。現account削除完了応答をPDF処理の消去完了と解釈しない。新機能公開前に接続を追加する。
- account_keyはhashでも照合可能な識別子。job/intake UUIDも結合可能なmetadataで、匿名情報ではない。

## 保存対象と期間案

| 対象 | 通常の保持/整理条件 | 消してはいけない条件 |
| --- | --- | --- |
| 原PDF/一時jobディレクトリ | 従来のrequest/実行の間だけ。成功/失敗/取消でreader・実子process・Container終了とtmp回収を確認 | 停止不明を消去済みと報告しない。新たな本文保管なし |
| manifest/解析本文 | 通信中だけ保持。完全受信/終了または中断で参照を破棄。complete検証前はiPad正式採用禁止 | 応答の再取得保証なし。同intakeを無条件再解析しない |
| intakeのPDF digest/bytes長/request ID | 撤回/取消/世代差替え/account削除で失効。期限切れは次の有限整理でcancelled化してdigest/長さをNULL、不要request IDを空へ | 将来receipt等が参照する詳細はその契約に従う。採用進行中を単なるageで破棄しない |
| intake最小行 | 当面account/document/最新generation/intake UUID/epoch/期限の拒否用記録を保持。行全体のDELETEは初版対象外 | 旧要求が同じnamespaceへ到達可能な間。現行の行数上限も残る |
| 未精算job | reserved/receiving/dispatched/stop_requestedは年齢にかかわらず保持し停止を試みる | claimed、remote ackだけ、token紛失、reader/verifier/consumer終了不明、recovery unresolved |
| 精算済みjob詳細 | 暫定でsettled_atから48時間以上、かつそのUTC日窓が閉じ、intakeが永続cancelled/置換済み、採用/復旧参照なしになってから候補 | 当日窓、時刻不明、遅延settle、処理/lease/採用参照あり。48時間は製品の保証値ではない |
| recovery | 親job未精算中は保持。精算済み・done・live leaseなし・job保持条件成立後に親と同transactionで削除 | remote_stoppedは全停止の証拠ではない。attempts/leaseを戻して再試行枠を復活させない |
| private DO | terminal＋destroy確認後にspent markerへの圧縮を設計。現2引数parseでは物理purge禁止 | running/finishing/poisoned、破棄/保存不明。小markerでもstorage課金0とは限らない |
| 将来receipt | 未解決の分散commitは保持。terminal後の詳細削減と再送fenceは採用工程で別契約化 | 片側成功/端末ack不明を期限だけで削除し、別文書として再採用させない |
| account/consent/document拒否fence | 既存の削除済み/失効/世代境界を維持。本文は保持しない | 同principal/同namespaceが再利用可能な間は単純TTL削除不可 |

48時間は初期の障害確認と再送対策の小さい運用案。別根拠で延長する場合はpolicy版を分ける。保持を短くしても、処理/会計/採用/fence条件は省略しない。最小拒否fenceを永続的に消すにはnamespace/account incarnation等の再利用不能な失効機構が必要で、現設計の一括削除では代用しない。cap到達時は受付を拒否し、容量確保のためfloorを削らない。

expiryからのdigest削減は、trusted scheduler稼働時に「1時間以内に試行」を初期運用目標とする。今はscheduler未有効でこのSLOを保証しない。DB障害や停止不明は別の遅延/残件として監視する。

## 整理の安全な順序

1. ユーザー削除/同意撤回では、まずaccount/consent/documentを永続的に失効させ、新規実行と結果採用を禁止する。通常の期限整理では期限切れintakeだけをcancelledへ移す。
2. intakeのstate変更とdigest/長さの削減を単一SQLで行う。既存triggerで関連jobをstop_requestedへ。単にexpires_atとcaptured nowを比較して親行を消さない。古いnowをbindした遅延reserve SQLも永続stateで拒否する。
3. reaperで停止要求。未claimのみ既存の条件付き0精算。claimedはremote/localの必要な実終了証拠を得るまで保持。remote ackはVM側だけの証拠であり、枠解放しない。
4. trusted精算時にsettled_atを一度だけ記録。再送で更新し保持期間を延長しない。取消/lease/採用処理と競合する場合は保持へ倒す。
5. 候補ごとに「settled_at+48h経過、過去UTC窓、intake永続失効/別UUID、current receiptなし、recovery done/leaseなし」を書込み時点で再確認する。候補一覧を読んだだけで無条件DELETEしない。
6. 同一D1 transactionでrecovery childを先に、job parentを後に削除する。参照整合性と条件をtransaction内で検証し、片側だけ成功ならrollback。changes確認後のJS例外だけで原子性を代用しない。
7. intakeのgeneration/失効fenceとDO spent markerは残す。将来の有限purge前提を満たすまでは物理削除しない。

当日会計を維持するため初版に新しい日次集計tableは作らず、過去窓だけを整理する。retentionで消した窓へclockが戻った場合はadmissionを拒否する単調なmin_admission_window境界が必要。整理transactionでこの境界を進め、全reserve writerが同じ境界を検査して初めてjob DELETEを許可する。旧writerが境界を無視できる間は物理job削除を有効にしない。未来clock異常はmass purgeを避けて停止・警告し、client時刻を採用しない。

## 初版で必要なschema・互換順

0010〜0013の既存ファイルは変更せず追加migrationで対応する（以下は仕様案、番号/実SQLはStep5で固定）。

- jobにnullableのcreated_at/settled_atと適切なindex。既存settledは時刻不明として保持し、deadlineから精算時刻を推測しない。移行時に保守的起算時刻を明示backfillする場合は別の検証済み移行として扱う。
- executor精算とreaperの未claim精算の両方でsettled_atを記録。旧Workerの精算でNULLになる行は削除対象外。
- retention controlにpolicy版/min_admission_windowを記録。全admission writerのfloor検査が配備済みでなければphysical purge disabled。
- job/recoveryの原子的削除に使う候補/結果検証、必要なFK/index、書込み時再認可を追加。receipt schema未対応の間はreceipt由来の可能性を無視しない。
- retentionは受付と別flag。schema不足/DB失敗/不明状態で閉じる。通常HTTPからpolicyや削除対象を受け付けない。

追加列を旧コードが知らないこと自体は許容するが、旧コードが期限/floor境界を破る状態で整理を有効にしない。部分配備中は詳細削減だけに限定する。

## private DOの有限purgeは別の前提が必要

将来v2のtrusted RPC envelopeへ、MCPが実dispatchから固定したjobId/pdfSha256/notAfterを入れる。notAfterは既存job.deadlineから延長不能で作り、private WorkerとDOがclaim前/実行前/結果前に検証する。client指定や新しいnowから作り直さない。trusted service bindingを認証境界とし、HTTPからこのenvelopeを直接受けない。metadata自体を認可証明と呼ばない。

- 旧2引数parseを拒否。deadline欠落・過大未来・bind違いは拒否。
- retry/cancel/recovery/receiptも同じnotAfterの値を維持するが、**notAfterは新規実行/採用の期限であり、停止を禁止する期限ではない**。期限後でも既存DOの停止・destroy・証拠取得を許可する。期限後かつstorageが空の場合は、新規parseを拒否したままVM destroyを確認し、不要なmarkerを新設しない。空storageだけでVM停止済みと断定せず、destroy/状態確認が失敗すれば停止不明を維持する。
- cancel-before-parseが期限内に届く場合は、遅延parseを拒否するmarkerと元notAfterを保存する。期限後の遅延cancel/recoveryでnotAfter/保持起算を延長しない。旧cancel(jobId)の期限不明入口はv2のpurge開始前に移行/停止する。
- terminal＋destroy確認＋固定notAfter/grace経過＋cleanup/leaseなしの条件でだけpurgeを検討する。graceは最大実行/後片付け/クロック許容/再試行の契約から決め、任意の短い値を置かない。
- この前提の実装/旧caller排除/実runtime検証前はspent markerを保持する。物理purgeを始めた後の旧2引数RPC版へのrollbackは禁止し、受付停止で戻す。

storageから個別keyを消すこととstorage全消去/課金終了は別。Cloudflareの[SQLite DO storage仕様](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/)を参照。deleteAllで空にした同IDが再度呼ばれる場合を必ず回帰する。namespace全削除による容量回収を通常cleanupへ組み込まない。

## account削除・receipt・バックアップ

account削除は認証失効と停止要求を先にし、PDF cleanup pendingと既存text/vector・認証情報・KV・課金連携等の消去を独立したphaseで追跡する。**PDF pendingだけをdeleteAccountRAGの例外として追加して後続処理を全部停止させない**。既存の認可/失効失敗はfail closedに維持しつつ、安全に独立して消去できる項目を継続する。

現在account-deletion.jsはdeleteAccountRAGの後にcredential/KV等を消すため、PDF専用の非本文checkpointとphase結果を呼出元の削除stateに追加し、セッション/identity mappingを消す前に停止対象と再試行の対応を永続化する設計が必要。成功済みphaseは繰り返さず、最後のstatus=deleted/完了応答は全phaseの完了判定へ結合する。PDFだけ未完なら処理中/残件ありとし、認証情報等が消去済みでも「全処理消去完了」と報告しない。checkpoint/schema unavailableで全完了に進めない。

未解決jobとowner対応は停止確認に必要な範囲で保持し、本文は永続保存せず、intake側のdigestは取消・期限切れ・account失効で削減する。Step5-D2aで追加するjob側rpc_pdf_sha256はPDFと結び付くmetadataであり、dispatch時に固定した後は取消・account削除でもNULL化しない。停止不明・未精算の間、およびpurge未接続/無効の間は保持が続く。精算済みでも48時間・過去会計窓・停止証拠等の既存条件を満たし、保守処理が有効化された親jobのpurge時にだけ一緒に削除する。匿名化済みと説明しない。

receiptはStep12〜15の正式採用と整合させる。未解決はageだけで削除せず、terminal後のhash削減/期限付き再送/fence/端末の復旧導線を明文化してから有限削除する。端末の保存とD1の採用を一つのtransactionで済むと仮定しない。

D1 Time TravelはPaidで過去30日までの復旧を提供する。[公式資料](https://developers.cloudflare.com/d1/reference/time-travel/)に従い、通常DBからの削除を即時のbackup物理消去と説明しない。復旧で失効・利用量・削除記録を巻き戻さない運用が必要。旧backupからactive jobを復活させてそのまま再開しない。受付/採用を閉じ、復旧後のepoch・削除状態と独立した削除要求記録の照合手段を具体化するまでは復旧後の再有効化を禁止する。外部削除記録の新保存先はこの設計では追加しない。

## 脅威・障害とrollback

- ageだけの削除：再実行/会計回避/世代巻戻り→永続失効、closed window、floor、参照再検査。
- cleanupとclaim/settle/receiptの競合：同SQL/transactionで勝者を固定。不確実なら保持。
- 停止不明・lease期限切れ：TTLを停止証拠にしない。needs_attentionと最古経過時間で運用対応。
- account削除と保持：詳細最小化を先にし、停止に必要な対応だけ残し、残件を明示。
- DB/clock異常：自動整理停止。解析を再送しない。raw errorやIDをログへ出さない。
- rollback：retention入口を閉じ、追加schema/floor/失効fenceを残す。消した詳細を復元する目的で旧active状態を戻さない。物理削除を有効にした後はfloor非対応writerへ戻さない。

## Step5のレビュー可能な実装単位

A. 追加schema/時刻と互換gate、期限切れintakeの取消・詳細削減、read-only集計、対象テスト。
B. closed-window/単調floor/旧writer排除/参照保護を揃え、terminal job＋recoveryの原子的purgeと失敗試験。
C. account削除callerへPDF pendingを接続（Step6の停止証拠契約と合わせる）。
D. v2 private RPC/DO finite purge、receipt有限保持は各契約完成後の別単位。A/Bだけを実装して全retention完了とはしない。

各passは候補/書込み各最大10件、全体10秒を上限案とする。選択用index/単一行操作のboundednessも確認し、LIMITだけでDB走査全体が有限と主張しない。初期scheduler/予算はStep7〜9で明示し、今回の設計では変更しない。監視はexpired-intake数、held/unsettled数、最古経過時間、候補/削減/削除件数、固定失敗分類だけ。本文/digest/owner/job IDs/token/生例外を出さない。

## Step5以降の受け入れ試験（今回は未実行）

1. 未claim/claimed/settledと全状態、日窓前後、0unitsを含む件数が整理前後で正しい。
2. 48時間境界、精算時刻不明、古いdeadlineを持つ今日の精算、再精算で起算時刻が変わらない。
3. captured nowを持つ遅延reserve、期限切れintake取消、古いprepare/世代0再送を拒否する。
4. claim/settle/cancel/lease取得/遅いRPCとcleanupの競合で枠・停止証拠を失わない。
5. child削除後のparent失敗、制約失敗、DB timeoutが部分commitにならない。
6. receipt未解決/後から採用競合、old worker/time欠落、schema不足で削除しない。
7. clock後退/過大未来、異なるpolicy版、10000行等の走査/index/期限で安全側へ倒す。
8. account削除後のPDF pendingを保持し、他の安全な独立phaseの消去を止めず、checkpoint/最後の完了判定を検証する。pending解除は実停止証拠で確認する。
9. DO空状態への旧parse再送、cancel-before-parse、期限後の既存DO停止、期限後の空DO取消でmarkerを増やさないこと、期限延長なし、再起動/遅延alarm/破棄失敗を検証。
10. purge後のrollback/backup復旧で旧権限/世代/会計/解析が復活しない。

今回の検証は現コード/DDLとの整合と独立設計レビュー。加えて全migrationを適用した合成のin-memory SQLiteで、0units精算済みjobを単純削除すると当日COUNTが1→0になる反例を再現した（実DBは無変更、新しい整理実装の回帰試験ではない）。新実装の機能テスト/SQLite回帰/実D1削除/実DO purgeは未実行。Step1固定sourceのhashは維持し、設計を稼働済みとしない。


## Step4レビュー結果

独立Plannerが現DDL/会計/停止/削除callerを調査。独立Code設計レビューのMedium2件（期限後cancel拒否の曖昧さ、PDF pendingが他のaccount削除phaseまで止める可能性）を修正し、再レビューで解消を確認。Security設計レビューも修正後に未解決所見なし。いずれも設計レビューで、実装合格・法的保持方針の承認・実DB削除検証を示さない。

Step4の設計成果は完了。次はStep5-Aの追加schema/時刻/互換gate/期限切れintake詳細削減/集計を、合成データによる回帰と独立レビュー付きで実装する。B〜Dの前提未成立部分を一括有効にしない。

## Step5-A実装の現在地

2026-10-19、[実装・検証結果](RAG_PDF_RETENTION_IMPLEMENTATION_REPORT.md)。Aはローカル実装完了。B〜Dとremote適用/有効化は未完。現在のflag/schema gateは整理用のみで、0014未適用でも停止/精算を閉じない。精算時刻はDB SQL実行時刻を次秒へ丸めた値とtrusted captureのMAXで保守的に記録し、旧NULLやsettled再送は変更しない。

## Step5-Bの具体化（2026-10-19）

[実装と試験](RAG_PDF_PURGE_IMPLEMENTATION_REPORT.md)。0015の別制御を初期無効で追加。永久writer fence、DBclock/lease、coarse候補最大10とcursor、親DELETE trigger内のfloor/child削除、batch全rollbackを実装。receipt導入前にpre-adoption契約を変更し旧purgeを閉じることが必須。48h/過去窓/永続失効/unknown保持の方針は維持。実DBの有効化やC/Dは未実施。


## Step5-D1実装の現在地（2026-10-20）

private v2期限固定と旧signature拒否の未接続部品を実装。cancelはjobId/notAfterの固定形でdigest不要、parseは実bytes digestを照合しDO stateにはdigestを保存しない。MCP側永続envelope/全caller移行はD2a、実停止/旧caller閉鎖/grace確定後のfinite purgeはD2b。今回物理purgeはない。[結果と制約](RAG_DO_V2_BOUNDARY_REPORT.md)。


## Step5-D2a MCP接続の現在地（2026-10-20）

0018でjobへrpc_version/rpc_pdf_sha256/rpc_not_afterを追加。v2 parseのenvelopeはdispatch CASと同時保存し、deadline=notAfterを固定する。取消・証拠・reaper・account cleanupはintakeに依存せずjobから停止契約を復元。v2 jobはflag OFFでもv2停止、旧pendingは元deadlineだけでv2取消へdrainし、digestやv2 parse契約を補完しない。新規受付flagは未設定、旧schemaでは新v2受付のみ閉じる。

追加のdigest保持は上記条件に従う。既存pre-adoption-stop-v2の親purge/FK/floor条件は維持し、DO stateの削除はしていない。実local workerd/D1/RPC/SQLite DOは合成VM IOで確認、実Container停止は未確認。[詳細と制約](RAG_PDF_RPC_V2_INTEGRATION_REPORT.md)。D2bは実停止・旧caller閉鎖・grace根拠を満たしてから。


## D2b-Aの前提確認（2026-10-20）

全消去するとDO内のclock履歴も消える。時計が大幅に戻り古いnotAfterが未来に戻ると空DOだけでは再送を判別できず、graceやlocal lastObservedAtだけでは安全にならない。Map fixtureでこの反例を再現した。外部単調fence/namespace incarnation、またはtrusted clockと異常時全入口停止の契約を別設計とし、今回は物理purgeもmarker縮約も実装しない。retention alarm/grace定数も未導入。

v2 stateのdestroyConfirmedAtはdestroy解決後に保存する最初の観測時刻だけ。保存/時計/alarm失敗は成功ackなし、poison/retry保持。過去の観測を現在の停止・全task静止・削除許可と見なさない。legacy/期限後空DOには追加しない。実Linuxの解析/取消/短縮期限kill/reap/SIGTERMを再確認したが、新v2の実Cloudflare Container停止は未検証。[詳細](RAG_DO_DESTROY_CONFIRMATION_REPORT.md)。


## D2b-Bの方式案（2026-10-20、未実装）

当面DO marker保持。有限削除へ進む第一候補は、新storageではなく既存jobの一回限りstart CAS。同nonce含め許可を再発行せず、unknown commitは停止/cleanup/枠保持へ進む。DO start直前の専用RPC、元inflight追跡、D1 terminal/消去、clock/backup復旧、alarm/graceと旧入口閉鎖まで揃わなければpurgeしない。外部DBを復元すると拒否根拠も戻るため、任意backup後の自動安全は保証しない。次C1は追加metadata/不変trigger/内部helperの未接続検証。[正本の比較・段階計画](RAG_DO_REPLAY_FENCE_DESIGN.md)。


## C1の保持契約（2026-10-20）

0019によりone-shot-v1の親jobは精算済みでもC1では保持しDELETE拒否、eligible viewをlegacy限定とする。coarse cursorは保持対象を通過でき、既存legacyの整理を止めない。新start claimは取消/account削除で消費をresetしない。新metadataの有限保持はC3/C4の契約成立後。floorのmonotonic/kept/no_replace guardがない新gateは閉じる。停止/精算の既存経路は維持。[C1結果](RAG_PDF_START_GATE_REPORT.md)。
