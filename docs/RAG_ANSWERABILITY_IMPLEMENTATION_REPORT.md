# RAGの具体情報に対する根拠判定

## 目的と受け入れ条件

関連する話題の抜粋だけで、質問が要求する数値・数式・価格・配列等の根拠がそろったと扱わない。
今回の範囲は要求1の具体情報チェック。Gemini最終回答の評価、追加モデル、iOS画面変更、migration、デプロイは含めない。

- 既知の同一話題・情報不足10問で、出典とretrieved contextを返さない。
- 実際に情報がある対応positiveを保持する。
- 対象・属性・値・年/温度条件を対応させ、本文の別の値やタイトルだけで承認しない。
- 複数の要求は、最終抜粋の集合で全項目を確認する。
- 通常質問、比較、ユーザー分離、RAG disabledの互換性を維持する。
- 外部AI呼び出しと本文ログを増やさない。

## 変更

- 新規 `mcp-server/src/rag/answerability.js`：canonical queryから具体情報の要求を抽出し、最終抜粋を評価。
- `mcp-server/src/rag/retrieval.js`：neighbor展開・削除確認・文字数制限の後に判定。根拠不足なら既存の `insufficient` と空context/citations。複数ページで項目を満たせる場合は、証拠に寄与するページだけ返す。
- `mcp-server/src/ai.js`：根拠不足は「取得した抜粋で求められた情報が見つからない」と伝える。資料全体に絶対に存在しないとは断定しない。一般知識で続ける場合は区別する。
- 新規 `mcp-server/src/rag-answerability.test.js`：欠落10問、対応positive10問、別対象・条件不一致・完全性・改行・複数ページ・最終本文の削除/切り詰め等。
- `mcp-server/src/rag-integration.test.js`：Geminiへ渡す固定指示・contextとSSE出典の契約を追加検証。
- 新規 `mcp-server/scripts/rag-quality/answerability-replay.mjs` と `docs/RAG_ANSWERABILITY_REPLAY_RESULTS.json`：保存済み100ページ評価の検索結果を使ったオフライン再評価。

## 判定と安全性

対象は価格、売上、型番、数式、導出、アミノ酸/塩基配列、分子構造、日時、明示的な数値要求。
属性名だけでなく実際の値・単位や式等を要求する。日本語の漢数字も扱う。
複合対象名を保持し、価格等は対象→属性→値のつながりを確認する。
質問の20℃を回答値と誤認しない。年/温度条件は同じ事実記述で一致させる。
明示的な不明・否定・命令文を除く。最新性や全量/一覧の網羅性は抜粋から証明できないため、保守的に根拠不足とする。

owner/scopeのSQL・Vectorize条件は変更しない。本文のタイトルやmetadataを根拠に使わない。
最終contextとcitationsは同じreference集合から作る。新しい外部送信、AI呼び出し、本文ログ、保存項目はない。
既存のuntrusted JSON扱いを保持する。指示文regexだけでprompt injectionが完全に防げるという主張はしない。

## 検証結果

- 修正前の再現：関連性の高い候補を返すテスト条件では、情報不足10/10で `grounded` と出典が返った。
- 修正後：同条件の10/10で `insufficient`、空context、出典なし。
- 各具体情報の対応positive10/10は出典を保持。
- RAG関連テスト78/78成功。ユーザー分離、削除、100ページbatch、通常/比較/曖昧な質問、reranker障害、disabledの既存回帰を含む。
- 全Workerテスト706/706成功（最終再実行、約44秒）。途中の全体実行で既存認証テストが1件偶発失敗したため、`local-auth.test.js`の乱数salt先頭1バイトによるdummy/upgrade区別を呼出し順に変更し、実際にresetが挿入されたこともassert。認証のproduction処理は変更しない。この修正の独立レビューと対象1/1成功も確認。
- 独立レビュー：対象/値・完全性のP2指摘を修正し、漢数字/見出し補正と最終本文の境界テストも独立確認。今回の限定範囲に未解決P1/P2なし。独立実行78/78成功。
- iOSは変更していないため今回再ビルドしない。旧SSE型と5種類のstatusは維持。

## 100ページの保存検索結果の再評価

実Cloudflare AIで以前測定した候補の最終ページを固定し、新しい本文判定だけを再実行した。
合成100ページPDFの抽出済み本文を利用し、各ページが1 childであることを再現時に確認する。
これは新しいEmbedding/Reranking実測、実Vectorize検索、Gemini回答評価ではない。

| 評価セット | 正解ページをすべて含むpositive：前→後 | negativeで出典を返した件数：前→後 |
|---|---:|---:|
| 元60問 | 52/55 → 52/55 | 0/5 → 0/5 |
| 追加40問 | 29/30 → 29/30 | 0/10 → 0/10 |
| 最終20問 | 10/10 → 10/10 | 5/10 → 0/10 |

評価中に「百八十度」の表記が誤って落ちることを発見し修正したため、これらは開発用の回帰セットであり、未使用の独立評価セットとは呼ばない。
Geminiが実際に根拠不足を正しく説明するかは、固定指示/SSEのテストのみ。実モデルの最終回答の品質は次の評価が必要。

再現例（生成・OCR済みの合成PDFの抽出結果を指定）：

```sh
cd mcp-server
node scripts/rag-quality/answerability-replay.mjs /path/to/synthetic/extracted-pages.json /tmp/answerability-results.json
node --test src/rag-answerability.test.js src/rag-quality.test.js src/rag-integration.test.js src/rag.test.js
npm test
```

## 限界・運用

これは保守的な形式/項目チェックで、一般的な意味の含意、事実の正確さ、完全性を保証するモデルではない。
未対応の言い回しは判定が働かないことがある。特殊な数式・表・OCR誤り・同義語は、正しい資料でも落とす場合がある。
通常の意味検索に対して汎用的な「答えが書かれている」保証を追加したわけではない。
最新/全量要求には関連資料があっても出典を付けない。部分情報を説明する表示や信頼できる更新時点/完全性metadataは別タスク。

本番設定は変更せずRAG_ENABLED=falseを維持。migration・環境変数・secretの追加なし。
ロールバックは新しいgate呼び出しと固定指示の今回分を戻すか、RAG_ENABLED=falseで通常チャットへ戻す。索引形式や保存データに変更はない。
