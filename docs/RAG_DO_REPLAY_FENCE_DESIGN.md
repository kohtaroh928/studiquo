# D2b-B: DO記録を消した後の再実行防止

2026-10-20。設計成果であり未実装。現在の安全な既定はDO marker保持。D2b-Aの[検証と反例](RAG_DO_DESTROY_CONFIRMATION_REPORT.md)を前提にする。remote配備・新storage・設定変更・有料API・物理削除を承認した資料ではない。

## 解決する問題と選択

現在のv2はnotAfterとDO markerで再送を拒否する。DO全消去と時計の大幅後退が重なると、空DOは古い契約を新規と区別できない。保存済みdestroyConfirmedAtも全消去で失われる。graceを長くするだけでは解消しない。

| 案 | 利点 | 負担・限界 | 判断 |
| --- | --- | --- | --- |
| 最小DO markerを保持 | 既存の拒否経路を維持。clock後退でもmarkerが残る | 小metadataの保持が続く。storage費用を0としない | 現在の既定を維持 |
| 既存D1 jobで一回限りstart CAS | 同時要求・再送・DO消去後の再試行を外部で拒否。新しい保存先なし | 追加DB書込み/RPC/可用性依存。失われた許可を再発行しない | 有限削除に進む第一候補 |
| 新namespace incarnation/専用tombstone保存 | DB復元と別の拒否境界を作りやすい | 新しい保持・配備・同期・監査が増える。世代復元にも注意 | 今回追加しない。backup対策として後で再検討 |

**read-only allowをキャッシュする案は採らない。** 「未実行をSELECT→無条件UPDATE」も採らない。同じjob行への条件付き書込みの勝者だけが一度許可を受ける。これは正確に一度の完了保証ではなく、再許可しない方針である。

## 正本と権限境界

- MCPは既存のowner/同意/intake/予算認可とdispatch CASを維持する。
- private DOはVM start直前にMCPの専用named WorkerEntrypointへstart claimを要求する。entryだけで確認してDO queue待ちに許可を持ち越さない。
- private WorkerにADMIN_DB全体のbindingを渡さない。gateはMCP内の固定操作だけを使い、任意SQL・owner検索・再送・一般状態更新・HTTP公開を提供しない。
- gate入力は固定envelopeとopaque startClaimIdだけ。PDF本文・manifest・生token・クライアント申告ownerを受け取らない。jobの保存済みaccount_keyから認可を照合する。UUIDが認可の代替ではない。
- 成功応答は固定shapeの許可と対応するopaque IDだけ。owner/digest/DB行を返さず、値・生例外をログへ出さない。
- cancel/destroy/evidence/recovery/account cleanupにはstart gateを要求しない。gate停止中・期限後もcleanupを残す。

named entrypointやbindingは現在存在しない。MCP→private→MCPの循環RPCについてcall depth・request寿命・切断・例外・timeoutを実local workerdで検証する。成立しなければ同じD1を使う小gate Workerへ抽出する代案を別レビューし、新しいserviceを自動作成しない。

## 追加するデータ契約（仮名、C1でDDLレビュー）

既存jobへ独立したstart_protocolとnullableなstart_claim_id/started_at等を追加する。RPCのversion=2と停止証拠claim_protocol=stop-proof-v1を流用しない。0018のrpc_version制約を勝手に3へ変えない。

- 既存行はlegacy/unknownのまま。start metadataがNULLでも「まだ安全に開始できる」と解釈しない。
- 新しいstart_protocolは、新規dispatch勝者CASと同時に一度だけ設定する。既存legacy/既にdispatch済みのjobへ後付けしない。
- startClaimIdはprivate側で作るopaque ID。返却確認用であり再grant権限ではない。同じIDの再送も拒否する。
- 初回消費は、契約・期限・最新認可・floorを同一UPDATEの条件で確認し、未消費→消費済みへ遷移させる。RETURNINGが1行の勝者だけ許可する。trigger副作用のchanges合計を勝者判定に使わない。
- gateの最初の必須条件はAI_PROVIDER_APPROVED/RAG_ENABLED/RAG_AUTO_INDEX_ENABLED/RAG_PDF_PROCESSING_ENABLEDの4flagと、専用start gateの有効設定（仮名RAG_PDF_START_GATE_ENABLED）がすべて厳密な文字列trueであること。OFF・欠落・不正値は拒否する。C1では合成envだけで有効化し、実configへ追加しない。SQL開始直前とgrant返却直前にも有効条件を再確認し、不明/停止なら許可を捨てる。遅延commitで権利だけ消費された場合も再grantせず保持する。env設定の変更とDB commitを一つの分散transactionにできたとは主張しない。旧deployのinflight遮断はC2/C3の運用・drain条件で扱う。
- gateが要求するDB条件: job存在/対象protocol/固定digestとnotAfter一致/notAfter=deadline/state=dispatched/token claimあり、現在のintake ID・generation・同意epochs・digest一致、account有効、両同意有効、未採用registry、DB時刻に対する期限、window_start>=永続floor。
- start metadataの変更/NULL化/reset、protocolのdowngrade、期限更新、ID再利用を認めない。最初のstarted_atはSQL実行時刻の観測であり実VM起動/停止証拠ではない。
- job欠落・settled・stop_requested・失効・schema不足・固定契約不一致・DB/RPC不明は拒否する。欠落からjobを新規作成しない。
- floorは新規admissionの過去窓を拒否する補助で、start認可そのものではない。notAfterから元の会計窓を推定しない。

start権利を消費したが応答を失った場合、同IDでもgrantを再発行しない。VMが動かなかった可能性を残して停止要求/cleanupへ進み、既存の両停止証拠なしで枠を解放しない。新intakeによる通常の再操作と、同jobの無条件retryを区別する。

消費metadataは親jobの保持対象。取消/account削除時に消費をリセットしない。未精算・停止不明は保持。既存parent purge/会計floor/証拠cascade契約へ追加protocolが与える影響をC1でレビューし、現purgeが自動的に将来start protocolを扱えると仮定しない。必要な契約更新は追加migrationで行い、0014〜0018を編集しない。

## 遅延した許可と停止の競合

1. DOはclaim前に対象契約を固定し、gateの**元promise**をinflightとして追跡する。timeout wrapperが終了しても追跡を消さない。
2. 開始時点のmonotonic時間を取り、gate呼出し開始から最大2秒を候補上限とする。返却時にもelapsedを再確認し、遅い許可は破棄。これは許可の陳腐化を制限する候補であり、全task終了やgraceの証明ではない。runtimeの時計挙動と負荷で値を校正する。
3. 許可後にDO内の元claim/状態/notAfter/取消/abortをVM start直前に再確認する。外部RPCをblockConcurrencyWhile内で待たない。局所再確認から同期startまでの競合を実runtimeで検証する。
4. 再起動で許可を復元・再利用しない。中断claimはpoison、再startは拒否。遅れた旧requestが再起動後の新requestへpermitを渡さない。
5. 取消が先に勝ったら新規startを閉じる。すでにstartが勝った場合は実VM停止へ進み、取消要求の時点で停止済みとは返さない。別service間で完全な原子取消になったとは主張しない。

元gate RPC・parse・read/reader cancel・monitor等の追跡、参照解放、VM destroyが未確認ならmarkerを残す。現在のdestroyConfirmedAtだけをこの判定へ流用しない。期限を過ぎたという理由でinflightを終了扱いしない。

## 物理削除の条件（まだ満たしていない）

- start gateが全新規起動経路で必須。旧signature、helper、flag rollback、旧Worker版、古いbindingからの迂回がない。新gateを無効化して旧parseへ戻す運用を禁止する。
- DO側の新規startを閉じ、元inflightが全終了、参照解放・実VM destroyを確認済み。legacy/unknownは有限削除対象に補完しない。
- D1でもterminal/失効、またはreview済retentionによる親job消去を確認済み。**D1がdispatchedの間は、DOがterminalでも物理削除しない。** start CASが消費済みなだけでは削除しない。
- cleanup/retryとretentionのscheduleを永続的に区別する。単一alarmで次の必要期限を選び、cleanup完了時にretention alarmを消さない。遅延/重複alarm・clock不明・保存失敗は保持する。
- graceは未決。125秒実行・10秒cleanup・retry間隔の単純な足算で決めず、元task停止/遅延RPC/clock差/receipt参照の契約を揃える。
- D1とDOの復元・旧code rollbackを含む運用確認、実Cloudflare Containerの停止/alarm、解除後の空DO再送を検証する。

## D1整合性・clock・backup

CASはprimaryへの条件付き書込みで競合を決着させる。後段readには新しいprimary/session文脈を使い、古い複製結果や呼出側bookmarkを開始許可の根拠にしない。実localとstagingで経路を確認する。D1 Sessions APIの逐次整合性を、任意の別sessionで常に最新という意味へ拡張しない。

この外部fenceはDOのclock後退/全消去に対し消費済み・closed・欠落で拒否する。全server clockの任意後退や、未消費の古いjobの絶対期限をclockなしで保証する仕組みではない。時刻不明/後退/gapの判定と拒否を既存clock/floor契約に合わせて設計する。

DB backupからjob/同意/floor/消費metadataを巻き戻すと外部fenceも戻る。同じDBのtimestampやtriggerだけでは防げない。復旧時は受付とstart gateをOFFのまま、削除要求・epoch・floor・start消費・DO状態を照合する。照合不能なら自動再開しない。任意backup復旧でも安全とは説明しない。独立incarnation等が必要になる場合は追加の設計/運用判断として残し、現時点でpurgeを有効化しない。

## 実装の順序と受け入れ条件

| 段階 | 今後実装するもの | 合格条件・範囲 |
| --- | --- | --- |
| C1（次） | 追加start metadata/不変trigger、内部start CAS helper、合成DB試験 | 既存行保持/同時二重要求/同nonce/固定契約・owner状態不一致/失効との競合/unknown commit・遅延commit/欠落schema/親消去後の拒否。4承認flagと専用gateの個別OFF/欠落/不正、await中/遅延CAS前後の停止とgrant破棄、消費済み保持、停止flag下のcleanupを回帰。既存停止・account・purge回帰。private/HTTP未接続、実flags/配備なし |
| C2 | named entrypoint、DO start直前の接続、元promise追跡/遅延permit拒否 | 実local循環RPC、取消先行/途中失効/timeout後許可/再起動/entry→DOqueue、gate停止中cleanup。marker保持のまま |
| C3 | clock/backup復旧契約、全task静止、alarm役割、graceを固定 | 証拠・実runtime・rollback手順を独立レビュー。不明なら有限削除しない |
| C4 | 最小markerへの縮約と物理purge | C1〜C3/旧入口閉鎖を満たした新protocolだけ。失敗は保持、clock後退/DO空/DB閉鎖・消去/旧code拒否を検証。初期OFF、配備は別承認 |

この表はRAG全体の新規scope追加ではなく、保留中D2bを検証可能な単位へ分けたもの。receipt/adoption導入前に親purge契約を再レビューする既存残件は維持する。

## 今回の検証と正本

既存DDL/dispatch/private開始/停止/purge/floor/Worker exportを読み、独立Plannerで代案・CASの採用理由・失敗時の枠保持を確認した。設計文書の整合/差分を確認する。production code・DDL・config・runtimeは今回変更/実行しておらず、D2b-Aのprivate51/MCP12/Linux成績を新機能の試験成績へ転用しない。

公式参照（2026-10-20確認）: [D1 primaryとread replication](https://developers.cloudflare.com/d1/best-practices/read-replication/)、[service binding RPC](https://developers.cloudflare.com/workers/runtime-apis/bindings/service-bindings/rpc/)、[DO state/input gates](https://developers.cloudflare.com/durable-objects/api/state/)、[alarm](https://developers.cloudflare.com/durable-objects/api/alarms/)、[SQLite deleteAll](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/)。上記はこのアプリの新gateが動作することの証拠ではない。


## 独立設計レビュー結果

Plannerはmarker保持を既定とし、read-only許可を先行せず一回限りCASを第一候補にする方針を確認。Code reviewは0018/停止証拠/parent purge/floorと照合し所見なし。SecurityのMedium1件（4承認flagとgate有効条件の欠落）を修正し、個別OFF/欠落/不正と遅延CAS前後の受入条件を追加、再レビューで解消確認。すべて読み取り設計レビューであり、新実装/DB/runtimeの合格ではない。diff check成功。


## C1ローカル実装（2026-10-20）

[実装と検証](RAG_PDF_START_GATE_REPORT.md)。0019/専用dispatch/内部start CASまで実装。新protocolはstop-proof-v1のclaim必須、既存行はlegacy/NULL保持。新protocol親はC1ではDELETE禁止、legacy限定viewで混在cursor前進を維持する。start_claimed_atは許可消費の観測でVM起動証拠ではない。private/HTTP/config未接続、C2〜C4は未実装。本文/生tokenの追加保存なし。
