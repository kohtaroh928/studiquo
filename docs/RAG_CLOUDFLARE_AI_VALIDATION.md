# Workers AI 実環境検証（2026-10-08）

既存アカウントのWorkers AI REST APIで実モデルを呼び出しました。Workerのdeploy、Vectorizeへの保存、RAG_ENABLEDの切り替えは行っていません。学習資料・個人情報は使用せず、合成した日本語教材のみ（多言語Embedding確認は合成英語も使用）を送信しました。認証値、入力本文、Embeddingベクトルはログや結果ファイルに記録していません。

## 結果

4条件×5回の20リクエストと、初期・多言語確認の2リクエスト、合計22リクエストすべてHTTP 200。

| 条件 | 成功 | 応答時間中央値 | 最小–最大 | Neurons/回 | 無料枠適用前のUSD/回 |
| --- | --- | --- | --- | --- | --- |
| query_embedding | 5/5 | 233 ms | 180–360 ms | 0.01 | $0.00000011 |
| index_embedding_16 | 5/5 | 418 ms | 371–901 ms | 5.45 | $0.00005995 |
| rerank_short_3 | 5/5 | 278 ms | 249–345 ms | 0.04 | $0.00000044 |
| rerank_15_children | 5/5 | 483 ms | 414–877 ms | 1.40 | $0.00001540 |

Embeddingは`@cf/baai/bge-m3`。queryの[1,1024]、index batchの[16,1024]を確認し、全要素が有限数であることを確認しました。index batchは実装と同じ最大16 childで、childは実際のchunkPageで生成した推定400–500 token以内の日本語本文です。実測child推定token数はJSONに記録しています。

多言語Embedding確認では関連する日本語・英語のcosineが0.7447、無関係な日本語資料とのcosineが0.3984でした。これは少数の合成例による動作確認であり、検索品質の総合評価ではありません。

Rerankingは`@cf/baai/bge-reranker-base`。実装と同じ`query`/`contexts`/`top_k:5`で15 childを評価し、5件のid/score形式と有限scoreを確認しました。短文3候補と15 childの両条件で、質問に対応する資料が全5回とも1位。短文scoreは約0.9117、長文の関連scoreは約0.0294で、絶対scoreの閾値による判断には利用できません。実装は順位を使用します。

15 childのRerankは全5回で既存の2秒deadlineを下回りました。測定はローカル端末→Cloudflare REST APIの往復（response body読取・JSON parseを含む）であり、deploy済みWorker内のbinding時間やHybrid RAG全体の応答時間を示すものではありません。同じ入力を各5回使用しており、cold start/負荷時/p95は測っていません。

## 費用

使用量は実responseの`cf-ai-neurons`ヘッダを集計しました。20回のbenchmarkは34.50 Neurons、初期確認0.10、多言語確認0.10を合わせて34.70 Neurons。表示値に丸めがあるため概算です。

Cloudflare公式料金の$0.011 / 1,000 Neuronsで換算すると、今回の22回は無料枠適用前で **約$0.0003817**。Workers AIにはアカウント全体で10,000 Neurons/日の無料枠があり、その残量・請求書は本検証では確認していません。したがって確定請求額とは区別します。

今回と同量の入力なら、query Embedding + 15候補Rerankは1.41 Neurons、約$0.00001551/検索（1,000検索で約$0.01551）。16 childのEmbeddingは5.45 Neurons、約$0.00005995/batch。入力長、言語、候補数によって変動します。Gemini、Vectorize、D1、Workers料金は含みません。

参考: [公式料金](https://developers.cloudflare.com/workers-ai/platform/pricing/)、[BGE-M3](https://developers.cloudflare.com/workers-ai/models/bge-m3/)、[BGE Reranker](https://developers.cloudflare.com/workers-ai/models/bge-reranker-base/)。モデルページの詳細token単価と料金一覧の丸め値が異なるため、本検証では実Neuronsを使用しました。

## 残る検証

- staging Workerの実AI bindingからの呼出しと、Vectorize/D1/Geminiを含む全体計測。
- 代表資料・OCR・実100ページPDFでの日本語検索品質評価。
- 多様な質問、時間帯、負荷での応答時間分布とtimeout/fallback頻度。
- 無料枠残量と確定請求額のCloudflareダッシュボード確認。

`RAG_ENABLED=false`を維持します。production/stagingのWorkerや保存データは変更していません。
