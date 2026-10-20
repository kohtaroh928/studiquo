# Step5-D1：private Docling v2期限固定境界

2026-10-20。`codex/rag-wip`。既存dirty保持、追加のローカル部品。MCP接続・記録物理削除・配備は行っていない。

## 今回の範囲

Step5-Dを独立レビュー可能な3単位へ分ける。

1. **D1（今回）**：解析側のv2期限固定・旧形式拒否・期限後停止。
2. **D2a（次）**：MCPのdispatch/recovery/evidence/account cleanupからv2へ全caller移行。dispatch前に再試行で復元できるimmutable envelopeを永続化し、旧jobの停止経路を維持する。
3. **D2b**：実runtimeの停止/期限/旧caller閉鎖とgrace根拠を確認後、finite purgeを別実装する。

既存MCPは旧parse/cancelを呼ぶため、新flagを今有効にすると互換性を壊す。今回flag/config/配備を変更しない。D1をfinite purge完成とは扱わない。

## v2契約

`DOCLING_RPC_V2_ONLY=true`のときだけ、private entrypointとDOの両方でv2を使う。parseV2は厳密な`{version:2,jobId,pdfSha256,notAfter}`、cancelV2は`{version:2,jobId,notAfter}`を受ける。extra key、型/範囲不正、非UUIDv4、実PDFとのdigest不一致を拒否。metadata/bytesを非同期処理前にsnapshotする。HTTPは404を維持する。

v2専用時は旧parse/cancelを入口とDOで拒否し、既存public helperのexecute/claim/cancelJobも旧引数では使えない。flag未設定では既存legacyの挙動を維持し、新v2入口は拒否する。コード上のRPCメソッドが増えたことを、公開HTTP APIの追加と混同しない。

notAfterはtrusted callerがdispatch前に固定して再利用する値であり、今回はparse時に最大180秒先までを受ける（既存MCP admissionの3分上限に対応）。期限内のclaimだけを許可し、内部実行deadlineはmin(notAfter, now+既存125秒)。claim排他境界・VM開始前・結果返却前に期限を再確認する。stateへrpcVersion=2とnotAfterを保存し、完了/失敗/取消/poison/alarm/再起動でも元の値を保持する。既存jobへの再parseは拒否する。cancelでnotAfterが違えば既存jobを中断しない。

実digestはbytesと照合するが、DO stateへPDF/digestは保存しない。cancelにはdigestが不要な固定形を採用した。D2aではintake詳細が取消・削減されても元の停止envelopeを復元できる永続journalを用意し、期限をnowから作り直さないことが必須。trusted callerが任意の別期限を再発行することまで、D1のmetadataだけで認証・防止できると主張しない。

## 期限後の停止と旧job

notAfterは新規実行/採用の期限で、停止禁止の期限ではない。execution flag OFFでもv2 cancelは許可する。期限内の空DOへcancelが来たら、元notAfter付きmarkerを保存して遅延parseを拒否する。期限後の空DOではmarkerを新設せず、VM destroyを確認してからだけackを返す。storageが空であることを停止証明にしない。destroy不明なら成功を返さない。

旧stateをv2 cancelで停止することは可能だが、欠けたnotAfter/rpcVersionを補完してfinite-retention対象にしない。旧記録は保持する。新旧callerの実移行と旧pending job停止の運用はD2aで確認する。

## 検証と限界

- private Workerの既存28＋新v2 13、合計41件成功。旧形式互換、v2専用拒否、厳密入力/digest/byte snapshot、期限境界、期限変更cancel拒否、cancel-before-parse、期限後既存/空DO、destroy失敗、claim直前/結果直前expiry、再起動/alarm、legacy停止を検証。
- MCP server全1,936 pass/0fail/0skip。MCP本体は今回変更していない。
- 実local workerdのSQLite DO保存/RPCで、固定期限、変更期限/legacy拒否、cancel前後の再parse拒否、期限後空DOでmarker非作成を確認。VM destroyは合成overrideであり、実Container停止やLinux解析の試験ではない。保存領域は一時作成して破棄。
- Plannerと独立Code/Securityレビュー、残所見なし。reviewerによる独立テスト/実runtime操作はない。diff check成功。

再現script: `mcp-server/tools/rag-docling-v2-local-smoke.mjs`。今回3source hashと結果はRESULTSへ保存。初回編集commandは作業directory指定の誤りで対象file未発見となったが、正しいdirectoryで実装・検証した。既存dirtyを戻していない。

DO保存の原子性・alarmの挙動は[Cloudflare storage API](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/)と[alarm API](https://developers.cloudflare.com/durable-objects/api/alarms/)を参照。単体のstorage削除を課金終了やnamespace消去と同義にしない。今回delete/deleteAll/purge/alarm整理仕様を追加していない。

## 次工程・rollback

次はD2aのMCP immutable envelope journal＋全停止caller移行。receipt/adoptionとfinite purgeは別工程。期限情報が失われた旧jobを今の時刻から延長しない。graceは最大実行/後片付け/時計/再試行の契約から決定し、任意の短い定数を置かない。

D1は未接続なので受付/配備状態変更なし。将来のpurge後はlegacy入口を再有効化するrollbackは禁止する。remote migration/deploy/実資料/有料AI/commit/pushなし、automation PAUSED。
