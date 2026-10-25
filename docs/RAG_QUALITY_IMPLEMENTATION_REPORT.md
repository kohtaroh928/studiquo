# RAG検索品質修正・検証報告（2026-10-08）

承認済みの③→②→①→④→⑤→⑥を実装しました。RAG_ENABLED=falseを維持し、0007のremote適用・deploy・pushは行っていません。適用済み0006は変更していません。実装・品質評価の完了と本番公開の可否は区別します。

## 変更

1. ③ canonicalQueryを意味検索・FTS・Rerankerで共用。原質問は会話用に保持。
2. ② 自然な指示語・理由・しくみなどの質問判定を拡張。主題不明はclarification。現在ページを明示した場合はowner/source/page条件内の資料を指示対象にする。追加LLM Rewrite呼出しなし。
3. ① RRF15を最大15件すべてrerankし、順位を3:1で融合してfinal Top5。3:1は保守的な初期設定で、汎用最適値として校正済みとは主張しない。不完全・重複・不正score・例外・2秒timeoutはRRF fallback。
4. ④ 比較対象と共通の質問内容を分離し、最大3検索。RRF15とfinal5の双方で主題の根拠を予約。1文字漢字（音など）も許容。同じsource/pageの重複をfinal5で整理。判定に資料タイトルだけを使わず、実際に送る参照本文でcoverageを確認。
5. ⑤ owner確認済みvector score/順位と重要語の一致で参照を選別。比較は主題別の関連性も確認。grounded/partial/insufficient/clarification/fallbackを追加SSEで返し、iOSに説明を表示・保存。Geminiへ支持されない主張を資料由来として断言しない指示を追加。groundedは参考資料の取得状態で、最終回答の正当性保証ではない。
6. ⑥ 日本語bigramを維持し、質問の汎用表現を整理。資料タイトル・ページ見出し・近い節見出しをEmbedding/FTS/Rerank入力へ追加。本文・ページ境界・overlapは保持。索引形式v2とEmbedding入力hashで再利用を判定する。

モデルは指定どおりBGE-M3（Embedding model v1、1024/cosine）とbge-reranker-base。Vector20/BM2520、RRF候補最大15、最終最大5を維持。検索本文をログへ出しません。

## migration・互換性

追加ファイルは0007_rag_context.sql。rag_sources/rag_pagesのindex_version/context_hash、rag_chunksのindex_version/embedding_hash/heading_contextを追加。既存行DEFAULT1。

- 旧0006だけの索引は読取・消去できる。新しい索引アップロードは503 index_upgrade_requiredで、HTTPのaccount reopenより前に止める。
- 同じv2入力は再Embeddingなし。タイトル・見出し変更は入力hash変更として必要なchunkを再Embedding。folder移動は新しい世代IDへEmbeddingをコピー。
- 次の通常アップロードでv2へ更新。タイトル変更のbatch途中では古いpage contextと混ざったsourceを公開しない。
- pending Vector ID・lease・削除競合・canonical user境界を保持。source消去では追加context_hashも消去する。
- 新SSEはRAG有効・専用同意ありのGemini requestだけ。旧アプリは未知eventを無視し、新アプリは旧serverのstatusなしを許容。disabledは従来request/SSEと完全一致。
- 新規binding/secretは不要。0007をstagingで適用し、検証後にproduction適用・Worker更新・明示再索引を別工程で行う。
- rollbackはRAG_ENABLED=false。現在の消去処理/schemaを残す。v2のcontext hash消去に対応しない古いWorkerへ単純に戻すことは推奨しない。

## テスト

- Worker全体671/671成功。RAG・品質・chat統合47件を含む。
- 独立Code Reviewerも最終46/46成功。タイトルだけの偽coverageと、検索後の削除で参照が欠けてもgroundedになる2指摘を修正し、回帰を追加。最終未解決P1/P2なし。最後に重要語整理が「説明責任」などの複合語を壊さない回帰1件を追加し、対象47件も成功。
- 独立Security ReviewerでP1/P2なし。schema preflightより先にaccount reopenするLow注意も修正・回帰追加。
- iOS全unit1521/1521成功（約22.2秒、署名あり）。Xcode最終TEST SUCCEEDED/exit0を確認。テストhostは正常終了し、最終Simulator診断収集の待ち時間が発生したが、アプリやテスト条件は変更していない。
- iOS関連unit47/47、UI3/3成功。全5status＋unknown、同意撤回、旧provider、保存、出典タップを確認。
- production/staging Wrangler dry-runとも成功。deployなし。
- Apple Sign In/CloudKit entitlements保持。ユーザーの生成済みprojectに不足していたSystemCapabilities属性だけ復元、project.ymlは変更なし。
- 100ページbatch/hash、旧形式移行、title変更、folder move、source/account削除、tenant/scope、prompt injection、Rerank不正/timeout、status、currentPage、disabled互換を回帰確認。

## 実Workers AIの品質

過去と同じ100ページ合成PDF（文字80/画像OCR20）・goldenページ・質問を使用。過去結果は上書きしない。OCR本文自体は以前と同じ抽出結果。FTSは実SQLite、vector検索はローカル厳密cosine。Cloudflare RESTで実Embedding/Rerankingを呼ぶ。

| 元の質問群 | 修正前 | 最終修正後 |
| --- | --- | --- |
| 言い換え | 17/20（85%） | 18/20（90%） |
| OCRページ | 18/20（90%） | 19/20（95%） |
| 比較・必要な両ページ | 5/10（50%） | 10/10（100%） |
| 自然な曖昧質問 | 1/5（20%） | 5/5（100%） |
| 資料外質問の根拠不足判定 | 0/5 | 5/5 |

必要な全goldenページ取得は41/55→52/55（94.5%）。最終60問では出典番号整合性は全件一致。中央値721 ms、最大3264 ms。途中の評価でEmbedding APIが約14.5秒かかった1問は10秒deadlineで通常chat fallbackになり、最終再実行では成功。遅延完了後に追加Rerankを始めないguardも追加した。

調整に使っていない40問の初回では、言い換え20/20、OCR5/5、比較4/5、資料外10/10が根拠不足。一文字の「音」を除外していた問題を発見し、比較主題別gateとともに修正。従って、この40問全体を最終版の未使用holdoutとして扱わない。

その後の20問検証では、肯定質問5/5・比較5/5が正解ページを取得。ただし同じ話題で資料にない詳細を聞く難しいnegative10問は、5問がinsufficient、5問は関連参照を返した。話題の関連性から回答可能性を完全には判定できていない。Geminiの最終回答での資料不足判定・幻覚は未評価であり、この結果で本番公開可能とは判定しない。

実教材の代表性、実Vectorize/D1 binding、実iPad、汚れ/傾き/手書き/複雑な図表のOCRは未検証。根拠gateの0.34/0.08/0.35/0.55/0.72は初期運用点で、実教材の十分なデータによる校正が必要。

## 保存した記録

- RAG_SEARCH_QUALITY_V2_RESULTS.json：最終元60問
- RAG_SEARCH_QUALITY_V2_HOLDOUT.json：初回未使用40問
- RAG_SEARCH_QUALITY_V2_VALIDATION.json：最終20問（難negative含む）

評価記録のplanはboolean/countだけにし、元質問・canonicalQuery・主題本文・Embeddingベクトルは結果へ保存しない。再現fixtureは明示的な合成資料のみ。遅延APIの計測が次の質問へ混ざらないようrequest-local traceで分離する。

## 主なファイル

Worker既存変更: rag/query.js、retrieval.js、storage.js、chunking.js、index.js、ai.js、rag.test.js、rag-integration.test.js。
Worker新規: rag/ranking.js、rag/relevance.js、rag-quality-fixture.js、rag-quality.test.js、migrations/0007_rag_context.sql。
iOS変更: RAGIndexingService.swift、AIProvider.swift、AIChatStore.swift、CalendarEvent.swift、RAGControlsView.swift、AIChatView.swift、StudiquoApp.swift、Localizable.xcstrings、RAGClientTests.swift、RAGCitationNavigationTests.swift。
評価: scripts/rag-quality/evaluate.mjs・README、holdout-fixture.json・validation-fixture.json、この報告とv2結果JSON、HYBRID_RAG.md・RAG_IMPLEMENTATION_REPORT.mdの追記。

## 本番前の残作業

0007 staging適用と再索引、実資料での重み/gate校正、同話題だが答えのない質問・Gemini最終回答の評価、実Vectorize/実iPadの確認。品質目標を満たすまでRAG_ENABLED=falseを維持する。
