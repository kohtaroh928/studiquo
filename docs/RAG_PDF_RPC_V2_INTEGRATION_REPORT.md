# Step5-D2a: MCPの固定v2契約と停止経路の接続

日付: 2026-10-20。ブランチcodex/rag-wip。既存未コミット成果を保持。High/full、独立Planner・Code・Securityレビュー対象。remote未適用のローカル実装である。

## 問題と変更

D1のprivate側は期限固定のparseV2/cancelV2に対応したが、MCPの解析・停止は旧signatureのままだった。intakeのdigestは取消・期限切れ・account削除で削減されるため、そこから停止契約を作り直す設計では復旧できない。

追加0018で既存rag_pdf_jobsにrpc_version（既存行1）、rpc_pdf_sha256、rpc_not_afterを追加した。新規v2はreceiving→dispatchedの勝者CASと同じSQLでversion/digest/notAfter=deadlineを永続化し、RETURNINGの保存値でparseV2を一度だけ呼ぶ。triggerは挿入時の偽v2、dispatch外の初回設定、設定後の改変・NULL化・downgradeと全jobのdeadline変更を拒否する。既存migrationを書き換えず、旧行にdigestやv2 parse契約を補完しない。

pdf-rpc.jsが解析の契約検証と取消RPC選択を担当する。取消・停止証拠・reaper・account削除はjobから契約を復元する。保存済v2は受付flag OFFでもcancelV2、失敗時の旧cancel fallbackなし。旧pendingをprivate v2-onlyで止める場合は保存deadlineだけでcancelV2へdrainする。private既存D1実装は変更していない。

RAG_PDF_RPC_V2_ENABLEDは未設定のまま。trueの新規受付は0018の列とtrigger確認を要求し、欠落なら本文読取前に拒否する。途中の受付flag変更は当該processのprotocolを変更しない。旧schemaで旧受付・既存停止/精算は維持する。既存local task追跡、reader cleanup、再認可、厳密remote ack、両停止証拠とlease/精算条件は変更しない。

## metadataと保持

PDF本文・raw token・解析結果を永続追加しない。ただし新job側rpc_pdf_sha256はPDFに結び付くmetadataであり、匿名ではない。intake digestの削減と区別する。取消・account削除でもjob側値は不変で、停止不明/未精算中およびpurge未接続・無効中は保持が続く。精算済み親jobについて既存48時間・過去会計窓・取消/世代・両証拠・leaseなし等の条件を満たし、保守処理が実行されたとき一緒に削除する。保持期間を実運用で保証した状態ではない。

追加tableなし。pre-adoption-stop-v2契約・FK evidence cascade・会計floorを緩めない。DO stateのfinite purge/deleteAll/spent marker圧縮は今回実装していない。

## 検証

新12回帰: MCP→実private entry/DOコード→合成VM IOの正常系、固定契約のDB保存、intake digest消去後/受付flags OFF後の復旧、旧pending drain、dispatch応答喪失、遅延CAS/取消先行、追加migrationの旧行保持/不変性、schema欠落時本文読取なし、v2失敗時downgradeなし、remoteだけでlocal証明不可、account削除、既存親purge、途中flag変更、旧claimのv2停止。

既存関連61件、新12件、最終サーバー全体とprivate側の結果は隣接RESULTS.json参照。テスト成功は回答精度の改善を示さない。prompt/検索/ランキング/有料API評価と開発30問/未使用20問は変更・使用していない。

新local smokeは実workerd・実D1の18migration・実サービスbinding RPC・SQLite DO storageを用い、MCP処理→private entry→DO→manifest検証→両証拠→精算まで通した。不変契約、intake消去後かつflag OFFの取消、旧parseと再parse拒否も確認。一時DB/DO storageを終了時破棄。VMのstart/monitor/ready/parse/destroyだけは合成IO adapterへ置換しており、実Cloudflare Container停止・隔離・Linux Doclingの再検証ではない。

中間の新テスト9/10はSQLiteのstrftime置換fixtureの引数数誤りでpurge試験が失敗、fixture修正後成功。local smoke初回はRPC proxyと普通objectのdeepEqual差異、次は同期拒否をassert.rejectsに直接渡した検証記法で失敗し、プロパティ比較とasync wrapperへ修正後成功。いずれもproductionの条件緩和で通していない。作業中の誤った相対pathの読取/ルートnpm実行は未実施として扱い、正しいディレクトリで完走結果を確認した。

独立Codeレビューに実装指摘なし。SecurityのLow1件（intake digestとjob digestの保持説明不一致）を保持設計・関連3資料へ修正。reviewerによる独立テスト/runtime実行はない。

## 公開・rollback・次

実配備・remote migration・新規flags/cron設定・実PDF・有料AI・commit/push/mergeなし。automation PAUSED維持。remoteの別系統migration照合・backup・承認範囲の確認は引き続き必要。

将来の移行は新規受付を止め、0018＋v2 cleanup対応MCPを準備し、private v2-onlyとMCP受付flagの整合を取ってから受付再開する。flag不一致は停止不明として保持する。rollbackは新規受付OFF、追加schema・保存契約・v2停止callerを維持。v2 pendingがある間は旧RPCしか知らないMCPへ戻さない。

次D2bでは実Container停止/期限/再起動・旧入口閉鎖・有限保持graceの根拠を揃えた後、terminal/destroyedの最小spent marker、固定purgeAt、cleanup/purge alarm分離、削除前再確認、削除後旧parse再開不能、clock異常時fail closedを別レビューする。receipt/iPad正式採用/資源費用校正/公開適用/ライセンス・OS監査の残件も維持する。

Notionは既存RAGカードへ着手/結果を記録。Project再同期対象はDATA_AND_MIGRATIONS/SECURITY_AND_PRIVACY/HYBRID_RAG。Desktop複製とclaude.ai uploadは今回行わない。
