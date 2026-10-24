# Step6-A：停止証拠とtoken紛失時の精算基盤

2026-10-19。基底commit `4debcd4`。High/full、独立Planner・Code・Securityレビュー対象。実装の現在地であり、公開接続や自動復旧の完了を意味しない。

## 何を解決するか

PDF処理が通信断になっても、解析VMの停止応答だけではサーバー内の受信・検証・結果処理が終わったとは判断できない。処理が残っているのに利用枠を戻すと、同時実行数やメモリの上限を超え得る。

元の処理が実際の終了を記録できていた場合に限り、実行tokenを失っても証拠を照合して精算できるようにする。証拠を書き込む前に元executorが消失した場合は枠を保持する。期限切れ、heartbeat欠落、管理者のbooleanだけでは停止証拠にしない。

## Aで実装したもの

- 追加0016。既存jobはlegacy、新しい内部claimだけstop-proof-v1へ。claim勝者のtoken hashと同一transactionのtriggerで最小証拠行を作る。raw token、owner、本文、digestは証拠tableに入れない。
- 内部scopeのrunで実taskを追跡し、sealで新規開始を禁止する。開始済taskのfinallyが登録するcleanupも収集し、task→cleanupの順で実promiseの完了を待つ。cleanup失敗/不明、payload返却は証拠保存を拒否する。
- ローカル停止証拠の保存後は再dispatchをDBでも拒否する。claim/protocol/保存時刻は固定し、証拠の巻戻し・置換・削除を拒否する。
- remote証拠はtrusted DOCLING_PROCESSOR.cancelの厳密なcancelled:true応答だけ。外部から停止済みbooleanやackを渡すAPIはない。未dispatchはlocal証拠とever_dispatched=0の組合せでのみremote不要と記録する。
- 両証拠が同一job/claim/protocolに結び付く場合だけtokenなし精算を許可する。dispatch済みは予約units全額、未dispatchは0。再送で精算時刻を変えない。停止cleanupは新規受付flagや同意がoffでも可能。
- 新protocolには旧stopConfirmed精算を許可しない。legacyの既存停止/精算経路は維持する。

## Bで接続する際の必須条件（A実装時の設計）

Aはpdf-process/pdf-job-recovery/HTTP/cron/configへ未接続。新規flagも配備設定へ追加していない。実際のreader/verifier/consumer/RPCをすべてscopeで追跡し、実reader cleanupを登録し、monitorを止め、payload参照を解放してからsealする必要がある。この内部能力は、任意の追跡外JavaScript処理の終了を自動証明するものではない。

回復passの件数/期限/backoff/lease契約を維持して、既に永続化した証拠だけを精算へ接続する。旧jobへの証拠後付けや、旧remote_stopped値の無条件流用はしない。証拠不足のlegacy/新jobは保持・可視化する。

## 保存期間と互換性

0016の新PDF証拠tableは0015の「既知5 table」のpurge契約を意図的に閉じる。physicalPurgeEnabled診断もfalseになる。証拠no-delete triggerも削除を拒否する。このため0016と旧purgeの同時利用は不可。Bで証拠child/親jobの原子的整理と契約版更新を独立レビューしてから再開する。これを終える前に全retention完了と扱わない。

rollbackは新claim入口を閉じ、0016・既存証拠・枠を保持する。証拠tableやtriggerを落として旧精算/旧purgeへ戻さない。Aは初期未接続なので本番状態の切替はない。

## 検証の区別

専用合成テストと全serverテスト、実local workerd/D1の再現scriptを使う。実D1のclaim成功判定はtriggerを含むmeta.changesではなくRETURNING件数で行う。runtimeのremote cancelは合成adapterであり実Docling/VMの停止検証ではない。実PDF、有料AI、remote migration/deployは使わない。

レビューでseal後に開始済taskが登録するcleanupを失うHighを発見し、登録受付の終了をtask drain後へ分離した。未解決cleanupがある間の証拠保存/精算拒否を回帰で確認し、Code/Securityの再レビューで解消確認。独立reviewerによるテスト再実行はない。

具体的な件数・runtime結果・今回source hashはRAG_PDF_STOP_EVIDENCE_RESULTS.jsonへ記録する。テスト成功はRAG回答精度改善の証明ではない。


## Step6-Bの現在地（2026-10-19）

実processor/reaperへ接続し、0017でFK cascadeを含む親/証拠の原子的retentionへ更新済み。配備設定は初期未有効のまま。上のA時点の未接続/旧purge閉鎖は0016単独の状態として維持し、現在の挙動・制約・検証は[Step6-B報告](RAG_PDF_STOP_INTEGRATION_REPORT.md)を優先する。
