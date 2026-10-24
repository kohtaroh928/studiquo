# 実Geminiによる出典選択shadow測定（2026-10-10）

実モデルの出典選択器を測るadapterを実装し、合成16問を実Geminiへ送信した。しかし、有効提案は0件だった。timeout・503・429により、必要事実の保持や出典削減の品質は未測定。公開RAGは変更していない。

## 対象と実施範囲

前回試作の `selection-proposal.mjs` に、固定Google API endpointへのtransportとlive評価runnerを追加した。Cloudflareの検索、Embedding/Reranking、最終回答、100ページPDFの再検証ではない。既存の固定候補から出典を選ぶ処理のみを測った。

- 合成fixture16問、dev/holdout各8。正解ラベルは送信しない。人間/教師のラベル確認と盲検評価は未実施。
- 要求モデルは製品defaultに合わせた `gemini-3.5-flash`。temperature 0、maxOutputTokens 4096、structured JSON output。
- 逐次1回ずつ、再試行なし、各5秒、全体最大20call枠。今回実際は16call。
- APIキーは既存の親リポジトリのローカル設定からメモリのみで読み、headerで送信。キーをURL・ログ・結果に含めない。
- 原文・prompt・モデル出力・APIエラー本文はログ/結果へ保存せず、静的理由・HTTP status・時間・usage等だけを記録した。
- public Worker、iOS、staging flags/secrets/DB/Vectorize、migration/bindingは変更しない。

## 実測結果

| 項目 | 結果 |
| --- | --- |
| 実API呼び出し | 16 |
| 有効proposal | 0 |
| 5秒でtimeout | 7 |
| HTTP503 | 2 |
| HTTP429 | 7 |
| 元候補へのfallback | 16 |
| usageMetadataを取得できた呼び出し | 0 |
| 実際の返却modelVersionを確認できた呼び出し | 0 |

終了までの時間は264〜5,002ms、中央値2,887.5ms。ただしエラーと時間切れの所要時間であり、正常なモデル応答時間ではない。timeoutの7件はHTTP status自体を取得できなかった。503はサービスの利用不能、429は利用制限を示すが、エラー本文を保存していないため、詳細なquota種類や503の原因は特定していない。

結果JSONの `allRequiredFacts=28/28` は**元候補に戻った結果**で、モデルの正答率ではない。validProposalが0なので、その必須事実保持の分母は0、品質評価は不能。出典数も元の52件のまま。

今回の測定はHTTP429停止処理の追加前に実行した。429後も残りを1回ずつ送ったため、16件を記録している。その結果を見てrunnerを修正し、今後は401/403/429を初めて検知した時点で残りの送信を止める。未送信数も明示する。修正後の遠隔測定は行っていない。原測定結果の `executionNote` にこの順序を記録した。

## モデルIDと費用の注意

調査中に、Googleの[公式モデル資料](https://ai.google.dev/gemini-api/docs/models/gemini-3.5-flash)で、3.5 Flashがdeprecatedで3.6 Flashへ自動転送されることを確認した。したがって要求IDと実際のモデルは一致しない可能性がある。今回は成功応答がなく実modelVersionを確認できていない。製品側のモデル設定は変更していない。次回は現行モデルを明示して試験する必要がある。

usageMetadataが全件未取得なので、使用トークン数・推定費用・請求総額は不明。JSONのusageTotalsの0は『観測できた分がない』という意味で、消費0/費用0ではない。timeoutでクライアントが切断しても課金される可能性がある。料金は[公式価格表](https://ai.google.dev/gemini-api/docs/pricing)と実モデル/usageの双方を確認して計算し、請求額は管理画面で照合する必要がある。

## 実装・検証

新規:

- `mcp-server/scripts/rag-quality/selection-proposal-gemini.mjs`
- `mcp-server/scripts/rag-quality/selection-proposal-live.mjs`
- `mcp-server/src/rag-selection-proposal-live.test.js`
- `docs/RAG_SELECTION_PROPOSAL_LIVE_RESULTS.json`
- 本報告。

更新: `docs/HYBRID_RAG.md` の現状追記。

transportはredirectを禁止し、レスポンスをstreamで64KiBまで読み、モデル本文は32KiBに制限する。AbortSignalをfetch/読み取りへ適用する。STOP以外の未完了応答を不採用とし、不正JSON/原文spanは既存検証器でfallback。構造上正常でも意味が完全とは認定せず、productionEligibleは常にfalse。

独立レビューで、HTTP429のbody取消が停止するとstatus通知が遅れ、runnerの停止判定が働かない反例が見つかった。HTTP status取得時点で同期通知するよう修正し、停止するcancelを持つ429 Responseの回帰テストを追加した。修正後に遠隔APIは再実行していない。

15件の対象テストが成功。HTTP error、サイズ超過、不正JSON、拒否、token上限による未完了、空出力、読み取り中timeout、認証/制限時の中断、ラベル非送信、usage集計、全入力の事前検証を確認した。Code ReviewerとSecurity Reviewerによる独立レビューを実施。最終修正後の全Workerテスト929/929成功（約49.4秒、失敗・skipなし）。iOS・実iPadは今回未実施。

## 運用と次の作業

実測プロセスは終了し、秘密情報の一時ファイルは作成していない。Cloudflareの公開状態を変更していないためサーバーのロールバックは不要。評価用adapter/runnerを除去すれば本変更を戻せる。プライバシーポリシーや本番データの変更はない。

次はGeminiプロジェクトの利用制限・現行モデルの利用可否を確認し、現行モデルを明示した少数の診断質問から再測定する。5秒を超える場合は、出力にoffsetを計算させる負担や出力の量を見直す。timeoutだけからoffset計算が原因と断定しない。実モデルの形式成功・事実保持・補足保持・費用を確認できるまで製品の出典削減へ進めない。
