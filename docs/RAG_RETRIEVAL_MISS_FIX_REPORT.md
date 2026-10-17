# RAGの取り逃し3件の修正・検証

2026-10-08、残タスク3「通常・言い換え2件とOCR1件の取り逃し」を修正した。
同じ100ページPDF・抽出本文・質問・正解ページ・根拠anchorで実Cloudflare AIの修正前後を測定し、必要な全根拠の取得が52/55問から55/55問に改善した。根拠なし5問は出典なしを維持した。
これは限定された評価セットの検索結果であり、製品全体の精度100%や最終回答の正確性を意味しない。

## 原因と変更

正解ページは意味検索・キーワード検索の上位に存在していた。しかし質問末尾の要求表現が語句一致率の分母を増やし、関連性フィルターで落ち、Rerankerへ届かなかった。

| 合成事例 | 正解物理ページ | 修正前の状態 | 正解候補の語句一致率 前→後 | 修正後 |
|---|---:|---|---|---|
| def-2：現象の名称 | 6 | 別ページを返すgrounded | 0.294→0.385 | ページとanchor取得 |
| def-12：割合の式 | 56 | 別ページを返すgrounded | 0.300→0.385 | ページとanchor取得 |
| ocr-17：冬の大雪 | 85 | 根拠なしfallback | 0.333→0.500 | ページとanchor取得 |

`src/rag/relevance.js`の検索用文のみ、末尾の「の名前／名称」「になるしくみ／仕組み」、比率の「どれほど／どのくらい／どれだけかを求める式」を限定して整理する。式を求める要求、実質的な対象、温度・年月などの条件は保持する。対象が指示語だけなら整理しない。
質問の原文・canonical query・Embedding・Rerankerへ送る質問・詳細根拠判定・検索閾値は変更しない。Query Rewrite/Multi Queryの判断や新しい生成AI呼び出しも追加しない。
今回OCR抽出コードは変更していない。OCR事例の原因も検索語の関連性判定だった。

評価ツールに、本文を保存せず候補の順位・所有資料のhash・ページ・語句一致率・意味スコアを保存する診断を追加した。
`candidateSignals.accepted`はcanonical queryに対する関連性判定であり、比較対象別の判定を含む本番の最終採用可否とは異なる。

## 実測結果

| 固定セット | 根拠の全anchor取得 | 根拠なしの出典抑制 | 実行失敗 |
|---|---:|---:|---:|
| 合成100ページ・修正前60問 | 52/55 | 5/5 | 0 |
| 同じ資料と60問・修正後 | 55/55 | 5/5 | 0 |
| 別の既存対照60問・修正後 | 40/40 | 20/20 | 0 |
| 公開教科書348ページ・30問再評価 | 24/24 | 6/6 | 0 |

すべての返却出典で所有者・資料・物理ページ・chunkの整合性チェックに成功。対照60問は既存holdout/validation fixtureの組み合わせで、未使用の独立holdoutとは呼ばない。
公開教科書の再評価は前工程と同じ固定manifestを使用した。比較3問（jma-21/23/24）は必要な根拠が取得できてもpartialのままであり、今回の修正で解決したとは扱わない。
対照の1問ではRerankの2秒制限によるfallbackが発生したが必要な根拠を取得した。

実Workers AI RESTでbge-m3とbge-reranker-baseを使用し、本番indexSource/retrieveを再利用。D1相当はローカルSQLite FTS5、Vectorize相当はメモリ上の厳密cosineである。実D1/Vectorize binding、近似検索、staging Worker、iPad、Geminiの回答生成は今回測っていない。
合成PDFは100ページ中20ページをVision OCRで抽出した。私有資料や一般のスキャンPDFへの精度を保証しない。
すべての登録で5ページbatch、同一sourceHash再登録による追加Embeddingなしを確認した。

| 実行 | AI呼び出し数 | Neurons | 検索中央値 / 最大 |
|---|---:|---:|---|
| 修正前 | 234 | 51.34 | 600.5 / 2,317ms |
| 修正後 | 235 | 51.60 | 600 / 1,987ms |
| 既存対照 | 225 | 52.81 | 565 / 2,554ms |
| 公開教科書再評価 | 412 | 319.39 | 823 / 1,423ms |

修正後に増えた1呼び出しは、以前根拠なしだったOCR質問の候補がRerankへ届いたため。速度比較は各1回の測定であり、性能改善の証明ではない。単位はCloudflare応答のNeuronsで、請求額ではない。

## テスト・独立レビュー

- 新規回帰テスト6/6。修正前は4件失敗し、修正後すべて成功。
- 関連RAGテスト110/110、独立セキュリティ担当の再実行も110/110。
- 既存を含む全Workerテスト740/740成功。
- 最後に追加した診断の数値型・項目whitelist・owner/scope・本文非出力の検証を含む評価ツール14/14成功。
- iOSコードを変更していないため、今回はiOSテストを再実行していない。
- 独立コード・セキュリティレビューで重大指摘なし。別担当が修正前後と対照の数値を再集計。

## 変更ファイルと安全確認

変更：`mcp-server/src/rag/relevance.js`、`mcp-server/scripts/rag-quality/real-material-evaluate.mjs`、`mcp-server/src/rag-real-material-evaluation.test.js`。
新規：`mcp-server/src/rag-relevance.test.js`、本報告、`RAG_RETRIEVAL_MISS_FIX_RESULTS.json`。

canonical user、accountKeyの生成とfilter、locked除外、scope、構造化出典、削除経路、本文を命令として扱わないcontext境界を保持した。本文・質問・Embedding・認証情報のログ追加なし。結果JSONは数値・状態・hash・ページのみで本文を含めない。
migration、binding、secret、料金設定、プライバシーポリシー上の送信先・保持方法の変更なし。deploy・本番データ変更なし。production/stagingのRAG_ENABLED=falseを維持する。
ロールバックは限定した検索語整理を戻す。schema変更・データ移行がないため再登録は不要。

## 再現用入力と残る作業

- 合成PDF content SHA-256: `cb7a64b4f17bc006c6729a0311e275f4bb383b9a0b429b95ed4379eb78faa523`
- 抽出本文 SHA-256: `59bd280dda8bbe47a71e53880cbedf849cb6e9dd3fd493c636e5891ac43e7710`
- 修正前後共通manifest SHA-256: `26a8db4a84ca3bc68c4b5475df89ee24f4f90f8eddc1975c436ddc63d7259eb9`
- 対照manifest SHA-256: `b9d3eb0d4baf8e5fe50355decea6c68966ebc238859833c7d6fcf8f1feda3b93`
- 公開教科書manifest SHA-256: `11f5c09ab227a0a334ad008ec341f8eb1f1e8fde2c6c6b24a6984b31011d043b`

私有入力・質問・anchor・実測原本は0700の`/private/tmp/studiquo-rag-misses-v1`と前工程のprivateディレクトリに保存。公開教材の本文はGitに追加しない。一時領域削除後には集計JSONだけでexact再現できない。
根拠取得は最終contextにanchorが残るかを評価し、回答の意味的正確性とは分ける。
次は比較・複合質問の主題／完全性判定、数式・実スキャンOCR、実D1/VectorizeとiPad経路、実教材のGemini回答品質、本番有効化前の運用確認が残る。
