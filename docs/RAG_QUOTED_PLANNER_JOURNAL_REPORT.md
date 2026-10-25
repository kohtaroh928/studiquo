# Quoted planner v3：通信なしの履歴・監査基盤

2026-10-15。[有限run設計](RAG_QUOTED_PLANNER_LIVE_DESIGN.md)の第1実装単位。新 `mcp-server/scripts/rag-quality/quoted-task-planner-journal.mjs` と専用テストを追加した。新moduleには通信・キー読取・CLI・ログ・自動起動がなく、API実runは作成していない。manifestの `transportAttached:false` は未接続を明示する。後段transportを追加する際は、そのsourceを含めmanifestを再固定し、現在の準備用journalを本番runへ転用しない。

## 実装

- 固定8job、checkpoint1/4/8、予約8192microUSD/件・累計65536を記録。実費とは異なる。
- private directory0700/file0600、排他lock、owner/inode/nlink、fatal UTF8、1MiB、hashchain、write長、fsyncを検証する。正常checkpointだけから再開でき、pending/failed/壊れた履歴を自動再開しない。
- 元quotedPlanだけを固定質問とv3 parserへ戻して位置を再解決し、保存resolved plan・usage・request bindingと厳密に比較する。undefined余剰fieldがJSONから消える誤合格も拒否する。
- stage_finishedの後はreview待ち。runId/manifest/checkpoint/件数/固定role/artifactHash/decisionが一致するcontinueだけ次stageを許す。stopは後続不可とする。8件生成完了と最終review完了を分ける。
- 書込後の呼出元mutationが保存済み履歴のメモリ表現へ波及しないよう、write前にsnapshot化する。異常時はhandleをpoison化し、後続操作を拒否する。
- 正常な終了だけでlock解除。解除後同期に失敗した場合のlock再作成はbest effortで、OS障害下の永続保持保証ではない。

## レビュー・確認範囲

独立設計レビューは元High設計で実施済み。第1単位の独立コード/安全レビューでHigh/Mediumなし。Lowとして、reviewは実artifactの存在/hash内容/本人性を認証していない点を確認した。これは**信頼した呼出元が実際の独立監査結果を登録するgate**であり、レビューの独立性を技術的に証明するものではない。後段では実成果物を確認しhashを登録する運用が必要。

対象12テスト成功。1+3+4、監査前の進行拒否、stop/binding、整形式の偽履歴、quoted/resolved不一致、source変更、保存後mutation、fsync/close/rmdir/directory同期故障、権限/リンク、巨大/不正UTF8、pending/failed停止を確認。最終独立再確認/全Worker結果は後記する。

[回帰表](RAG_QUOTED_PLANNER_LIVE_TEST_MATRIX.md)の通信/secret/body/deadline/API failureなどの統合ケースは未実装。第1基盤をAPI実行の全体gate完了やモデル品質改善とは扱わない。旧runner/契約/fixtures/3つの失敗runは保持する。

## 次

有限transportと固定phase/status/理由の診断を接続し、stage時間60/180/240秒・request60秒・byte/secret制限を実装する。全回帰・独立コード/安全レビューを通すまでは実API送信を行わない。rollbackはこの新moduleを使わないことで可能、DB/migration/deploy不要。今回は追加API/キー読取0。Projectの資料の更新: なし。


## 全体検証結果

全Worker1,414成功（失敗/skip0、45.6秒）、ログ `/private/tmp/studiquo-quoted-journal-all.log`。本文なし結果 [RAG_QUOTED_PLANNER_JOURNAL_RESULTS.json](RAG_QUOTED_PLANNER_JOURNAL_RESULTS.json)。独立安全の最終12テスト成功。旧v3IO/source hashと旧3run lock保持、構文/差分確認済み。iOS未変更・今回未実施、モデル評価未実施。コード最終レビューの確認を追記する。

最終独立コードレビューも12テスト成功、未解決High/Mediumなし。第1単位の通信なし基盤は確認済み。transport統合後の全体安全gateと実API確認は未完了。
