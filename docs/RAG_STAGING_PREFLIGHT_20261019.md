# Step 2：staging配備・DB・利用条件の読み取り確認

2026-10-19 JST。既存Cloudflare OAuthで配備情報とDBの管理metadataだけを照会し、Workersプラン画面の「現在のプラン」を確認。remote deploy、migration適用、DB作成/書込、設定/プラン変更、Container起動、モデルAPI呼出しは行っていない。[構造化した記録](RAG_STAGING_PREFLIGHT_20261019.json)。

## 現在の配備

- 対象 `studiquo-mcp-staging`、deployment `d24dbe37-bda9-4abe-9356-9499208be1bc`。
- 現在100%のversion `660d8caa-f695-4dd0-bddb-4a4aad50995b`、version番号83。配備日時2026-10-18 14:42:42 JST。履歴を日時で比較して取得し、一覧先頭を最新と推測していない。
- compatibility dateは2026-08-27、runtime migration tagはv5-mcp-inbox。実行環境の設定を読んだもので、Gitのcommit対応やremoteソース同一性は未確認。
- `ADMIN_DB`は設定中の `studiquo-admin-staging` と同じDB IDへbindされている。
- 実配備の `AI_PROVIDER_APPROVED=false`。RAG_ENABLED/AUTO_INDEX/PDF_PROCESSING/PDF_CLEANUPの変数は存在しない（falseの文字列が設定済みとは区別）。現ローカルコードは明示trueだけで許可する。
- 現配備にAI/RAG_VECTORIZE/RAG用3種rate limit/DOCLING_PROCESSOR bindingはない。ローカルの設定準備をremote適用済みとは扱わない。
- 認証済みContainers一覧は0件。Doclingのremote Containerは未配備。アカウント固有の配備quotaや実image受理は未確認。

## DBの適用状態

`d1_migrations`とRAG関連table名だけをSELECT。利用者データ/本文は読んでいない。DB IDがstaging bindingと一致し、両照会のmetaはrows_written=0、changed_db=false。

このブランチの未適用は次の6件。

1. 0008_rag_control.sql
2. 0009_rag_metadata.sql
3. 0010_rag_raw_pdf_consent.sql
4. 0011_rag_pdf_intakes.sql
5. 0012_rag_pdf_jobs.sql
6. 0013_rag_pdf_job_recovery.sql

さらにremote履歴には、基底候補に存在しない0006_legacy_standard_accounts.sqlと0007_moderation.sqlがある。履歴のid最大値9や数字prefixだけで「0009まで適用済み」と判断しない。既存の基盤変更/実配備ソースとの照合が配備前の残件。別履歴を削除・番号変更して合わせない。

Wrangler4.130の `d1 migrations list` は内部でmigration table初期化を呼ぶため、読み取り限定の今回は使用しなかった。既存sqlite_schemaをSELECTしてtableの存在を確認し、続けて既存履歴だけをSELECT。公開CLI名がlistでも無変更と仮定しない。

DB backupやTime Travel復旧点の取得はこの段階では行っていない。後の実配備直前に既存状態を再確認し、承認範囲で復旧準備を行う。

## 利用条件と費用

DashboardのWorkersプラン画面でWorkers Paidの「現在のプラン」、月額$5＋使用量を確認。既に加入しているプランであり今回追加購入なし。[公式Containers料金](https://developers.cloudflare.com/containers/platform/pricing/)も確認した。

現候補standard-1は0.5vCPU/4GiB memory/8GB disk、max_instances=1。超過時の単価はmemory $0.0000025/GiB-second、CPU $0.000020/vCPU-second、disk $0.00000007/GB-second。memory/diskは割当量、CPUは実使用に応じる。月内同梱枠は25GiB-hours/375vCPU-minutes/200GB-hours。料金表は2026-10-19照会時点。

単価だけの参考計算: 同梱枠を無視し、当該instanceを60秒実行してCPUを上限まで使用すると、compute部分は約$0.001234。起動/待機/停止時間と実CPU、同梱枠残量に依存するため「PDF1件の請求額」やhard capとはしない。Workers/DO/D1/ログ/egress等は別。今回請求明細・当月同梱枠残量・他プロジェクト利用の内訳は確認していない。max_instancesとshadow unitsは金額上限ではない。

[Workers料金](https://developers.cloudflare.com/workers/platform/pricing/)、[公式D1 CLI](https://developers.cloudflare.com/workers/wrangler/commands/d1/)、[Workers配備CLI](https://developers.cloudflare.com/workers/wrangler/commands/workers/)。

## この工程の結果と次

Step 2の現状調査は完了。配備可否の最終承認や準備完了の意味ではない。次はStep 3のOS依存/モデルライセンス確認。配備前のStep 8〜9では別系統の更新との照合、既存版の復旧、DB復旧点、必要bindingと実quotaを再確認する。

sandbox内の最初のremote照会は通信制約で失敗。エラーJSONを空一覧と誤認しないよう照会用の一時集計処理を修正し、正規の権限で再照会してから成功結果だけを記録。元の失敗を実アカウントの未配備/未認証証拠には使っていない。CLIログ/telemetryを無効にし、連絡先・token・secret値は保存/表示しない。

Step 1の固定374ファイルを再照合し、hash不一致0。今回の追加は報告・計画・引き継ぎだけ。機能テストは再実行していない。独立コードレビューは今回は対象なし（read-only調査）。
