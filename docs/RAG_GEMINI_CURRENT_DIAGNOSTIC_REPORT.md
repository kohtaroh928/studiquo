# 現行Geminiの利用可否と出典選択の再診断（2026-10-10）

現行3.6 Flashへの短い質問は正常応答した。しかし、その後の出典選択では最初の1問に503が返り、残り3問の送信を中止した。APIキー・モデルを使って基本的な生成は可能だと確認できたが、選択品質はまだ評価できていない。

## 実施範囲と受け入れ条件

外部API・秘密情報を扱うため、fullの安全確認、PlannerとSecurity Reviewerの事前レビュー、Code Reviewerの独立レビューを行った。秘密情報・原文・自由なエラー本文を保存しない、呼び出し数/本文サイズ/時間を制限する、利用不能なら以後の送信を止める、公開設定を変えないことを受け入れ条件とした。

評価コードだけを変更し、Worker公開経路、iOS、Cloudflareのflag/secret/DB/Vectorize、migration/bindingは変更していない。合成資料だけを使用し、実ユーザー資料は送信していない。

## 実モデルで確認したこと

| 測定 | 結果 |
| --- | --- |
| 極小質問での利用可否 | HTTP200、完成したtext回答あり |
| 要求ID/返却modelVersion | 両方gemini-3.6-flash |
| 所要時間 | 1,832ms |
| 使用token | 入力7、回答1、思考93、合計101 |
| 出典選択pilotの最初の問題 | HTTP503、2,289ms、fallback |
| pilot予定/実行/未送信 | 4問/1問/3問 |
| 有効な出典選択案 | 0件 |

短い質問の回答本文は保存していない。診断は1call・最大20秒・retryなし。その成功を条件として、生物比較・入力出力・分散した材料/生成物・暗所条件の4問を選択pilotに予定した。pilotは最初の生物比較で503となり停止した。原文baseline5件を維持した結果の必要事実2/2を、モデルの保持精度として扱わない。

今回の成功はキーと3.6モデルへの基本的な呼び出しがその時点で可能だった証拠。前回の429のquota種類、503の詳細原因、5秒timeoutの原因、恒常的なサービス可用性までは分からない。割当残量や課金設定の管理画面は確認していない。[公式トラブルシューティング](https://ai.google.dev/gemini-api/docs/troubleshooting)も、過負荷・制限と生成設定・思考による遅延を分けて扱う。

## 評価コードの修正

新規:

- `mcp-server/scripts/rag-quality/gemini-diagnose.mjs`: 固定3.6 endpointへの1call診断。成功/エラーとも16KiBまでstreamで読む。20秒の全体deadline。エラーの既知status/reason、数値quota/retryだけを保存し、message/project/metadata/本文は除外する。返却結果をdeadline時点でコピーする。
- `mcp-server/src/rag-gemini-diagnose.test.js`: 診断の回帰テスト8件。
- `docs/RAG_GEMINI_CURRENT_DIAGNOSTIC_RESULTS.json`: 2callのメタデータと制約。
- 本報告。

更新:

- `selection-proposal-gemini.mjs`: 評価用モデルを3.6へ明示。temperatureを1、thinkingLevelをminimalとした。原文span/ID検証、本文予算、5秒deadline、閉じた製品ゲートは維持。
- `selection-proposal-live.mjs`: HTTP5xxでも後続送信を停止。費用をrunner自身は計算しないことを明記。
- `rag-selection-proposal-live.test.js`: generation設定と503停止を検証。
- `docs/HYBRID_RAG.md`: 現状追記。

3.6のminimal対応は[公式thinking資料](https://ai.google.dev/gemini-api/docs/thinking)で確認した。temperature1は[公式トラブルシューティング](https://ai.google.dev/gemini-api/docs/troubleshooting)の推奨に合わせた。モデル・temperature・thinking・外部サービス状態が同時に変わるため、前回との差の原因は断定しない。公開チャットのモデルは変更していない。

独立レビューで数値の暗黙変換が指摘され、空白/配列/16進文字列をquota0等へ変換しないよう修正した。整数または十進整数文字列だけを受け付け、その他はnullとする。quotaのfree/paid/windowは返された識別子からの分類であり、課金設定の確認ではない。

## 費用

2026-10-10確認の[公式価格表](https://ai.google.dev/gemini-api/docs/pricing)では、3.6 Flash Standardは年末まで入力$0.75/100万token、出力（思考を含む）$3.75/100万token。診断の観測使用量で有料Standard相当を計算すると:

`(7 × 0.75 + (1 + 93) × 3.75) / 1,000,000 = $0.00035775`

これは成功した短い診断1callだけの換算額で、確定請求額ではない。実際の無料/有料tierは未確認。503になった選択callではusage未取得なので費用不明。前回のtimeout・失敗callも含めた総開発費は今回の結果から計算できない。

## 検証と未完了事項

関連テスト24件成功（診断8＋transport/live16）。機密の除外、入力値、response上限、timeout、遅延した結果が診断を上書きしない構造、HTTP5xx時の停止を検証。全Workerテスト938/938成功（約43.7秒、失敗・skipなし）。コードと安全性の独立レビューを実施。iOS・実iPadは今回未実施。

診断とpilotのプロセスは終了。キーの一時保存は行わず、結果に本文は含めない。本番やstagingの公開状態を変更しないためサーバーロールバックは不要。評価ファイルを除去/評価設定を戻す範囲で戻せる。プライバシーポリシー・データ削除方針に変更なし。

次は、サービス利用不能の詳細を安全な分類で診断できるよう選択adapterにも接続し、利用可能なタイミングで少数のpilotを再測定する。出典選択の原文offsetをモデルが正しく返せるか、必要事実を守れるか、5秒に収まるかは未確認。503から本文サイズ・offset計算等が原因だと決めつけない。公開RAGへの出典削減の接続や本番有効化はまだ行わない。
