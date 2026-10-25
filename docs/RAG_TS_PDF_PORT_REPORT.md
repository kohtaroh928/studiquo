# PDF停止証拠・開始許可のTypeScript移植

2026-10-21。作業先 `codex/rag-start-ts`、基点 `960f83d`（TS版）。旧成果 `dae6129` は `codex/rag-wip` に保持する。ユーザー承認でTS版から専用worktreeを作り、53ファイル分の未統合成果を選択移植した。main/Claudeブランチは編集していない。

## 範囲と現在地

0016〜0019、新PDF停止証拠/owner cleanup/v2 RPC/一度だけの開始許可、既存process/recovery/jobs/retention/purge、private v2停止観測、対応回帰とlocal smokeをTSへ移植。importは実在する`.ts`へ変更。MCP sourceのallowJs/strictを緩めず、productionへts-nocheckは付けない。private Workerは従来どおりテスト用設定の型検査対象で、専用strict設定は未導入。既存TS移行方針に合わせた歴史的fixture・smokeはts-nocheckであり、型検査成功をそれらの静的型安全性とは扱わない。既存anyも全面解消していない。

**C2のnamed開始gate接続は今回まだ行っていない。** C1相当の開始許可DB部品は未接続のまま。HTTP/実config/binding/cron/配備の有効化、marker削除、親保持解除、prompt変更、有料AI、実PDF、commit/push/mergeは行っていない。automationはPAUSEDのまま。

## TS版のアカウント削除を保持した統合

JS側の削除実装を上書きせず、TS版のgeneration/再登録・stillDeleting・alias保護・token/passkey index・libraryID消去・room最終cleanupを維持した。PDF-only再試行は同じgenerationのdeletingで独立phase完了済みの場合だけ。待機中の所有確認はcanonicalとaliasのdeleting/ofを照合し、helperからnested recoveryへも伝播する。確認のawait後、SQL/RPCを新たに開始する直前、結果採用前に期限と所有権を確認する。

最終markerはgenerationとidentityHashes。PDF対象の場合だけ固定完了metadataを追加し、生identityは残さない。alias完了後canonical保存に失敗した再試行は、同世代・PDF完了・identity hash集合完全一致の自分のalias markerだけを認める。別世代/別所有者/active aliasは操作せず保留する。

旧JSのlegacy deletedをdeletingへ戻す経路は移植しない。TS版では再登録がgenerationを進めるため、新世代を上書きし得る。PDF完了記録がなくschemaあり/DB不明のlegacy deletedは、主marker/jobを変更せずpendingを返す。hash-only aliasからRAG owner keyを復元できないため、自動で全完了と推測しない。この互換照合は残件。

TS基点後にmainへ入った `3b6b06d` の同時削除修正も、関連helperと53b回帰だけ選択的に反映した。同じ削除世代で別runが先に完了したとき、そのrunだけが把握していた旧tokenのsnapshot/actionsを清掃する。新世代には触れない。ブランチのmergeは行っていない。

KV照合とD1書込みを分散原子操作にしたわけではない。既に発行されたSQL/RPCは停止済みと推測せず、遅延完了し得る。保持中slot/proofの既存契約を維持する。

## 検出して修正したtimeout境界

全体試験で、timerが丸めによりmonotonic期限の直前に発火した後、schema待機が解けるとCASへ進むC1境界を検出した。開始gateはtimer発火/finallyで不可逆にclosedにし、遅いschemaから新しいCASを開始しない。monotonic値を固定した追加回帰でも確認する。owner cleanup/recoveryにも共通生存確認を渡し、nested passが外側期限を延長しない。RPC単体の操作timeoutとpass全体の期限切れは区別し、単体timeoutは遅い結果を捨てながら、有効なpass内で次の操作によるtimeout結果記録を許可する。

途中の全体試験は2回失敗した（最初は上記schema後CAS、次は追加expired flagでRPC単体timeoutまでpass全終了扱いにした回帰）。どちらも実装を修正し、既存assertion/production期限を緩めず対象試験を再実行した。全体の現ソースでの最終結果はRESULTSを参照。

## ローカル実行基盤

TS基点の直下Miniflareは互換日2026-08-27を扱えず、Wrangler同梱版とはAPIも異なった。依存/lockfile/互換日/実configを変更せず、local-only adapterでインストール済Wrangler同梱runtimeを使う。private TSをscript文字列へ渡すときは型を除去する。一時D1/DO storageは終了時に破棄し、VM IOは合成adapterのみ。

TS基点は既存0006/0007の2組を含む。合成SQLiteでは全21本（0019まで）、v2RPC試験は20本（0018まで）を適用する。番号衝突はremoteの適用履歴/運用確認が未解決であり、local成功をremote migration承認にしない。適用済migrationの改名/書換えはしていない。

## 検証・レビュー

最終: 型検査成功、全体2447件中2446成功/失敗0/既存方針skip1（51660ms）、対象69成功、account関連136成功、private51成功。gitleaks検出0、diff check成功。今回開始processは全終了。Notion既存カードと共通handoffを更新済み。

結果と現ソースhashは隣接 `RAG_TS_PDF_PORT_RESULTS.json` に記録する。歴史的JS report/RESULTSのhashや成績は書き換えず、今回のTS成果とは区別する。

Planner/Code/Securityの独立read-onlyレビュー。世代確認の伝播、alias完了→canonical失敗からの再開、legacy DB不明、guard待機後の期限、nested recoveryの外側期限を指摘に応じて修正し、対応回帰を追加した。reviewerの確認は独立テスト実行ではない。

## 次の作業とrollback

移植の型検査・回帰・local runtimeを確定後、C2でnamed WorkerEntrypoint/開始直前RPC/元promise追跡/遅延grant拒否を接続する。C3clock/backup/alarm/grace、C4有限削除は未実施。rollbackは受付を閉じ、消費記録・停止証拠・親保持を維持する。旧parseへのfallbackや消費resetは使わない。

Project再同期対象: DATA_AND_MIGRATIONS、SECURITY_AND_PRIVACY、HYBRID_RAG。Desktop複製/uploadは変更していない。
