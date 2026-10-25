# RAGの必要情報・原文根拠選択 (2026-10-10)

作業先: `.worktrees/rag-wip`、ブランチ `codex/rag-wip`。この報告はローカル実装時点の記録。[実モデルstaging続報](RAG_EVIDENCE_SELECTION_STAGING_REPORT.md)で条件保持・重複削減を確認済み。reserve補充は今回発動せず実環境確認が残る。stagingは再び無効。本番有効化の判断は行っていない。

## 要件と実装

利用者の質問に必要な情報が上位5件にそろわない場合、既に検索したTop15から追加の根拠を補う。元のAIProvider→Worker→Gemini構成、Hybrid/RRF/reranking、認証、APIの出典形式を維持する。

1. 既存の質問解析による比較対象と、価格・型番・数式等の具体的属性を「必要な情報」に整理する。新たなLLM呼び出しは追加しない。
2. 元本文の段落から具体的な根拠がある位置をUTF-16のstart/endとして特定し、Geminiへ送るuntrusted referenceに`evidenceSpans`を付ける。本文・値・数式は生成し直さない。段落だけでは遠くの条件を判断できないため、既存の最大6,000文字のexcerpt本文を保持する。一般的な仕組みの説明など具体的属性を判定できない質問には、根拠位置を無理に付けない。
3. 必要情報が欠けるときだけTop15の残りを同じowner/scope SQLで最大5回追加読み込みする。各追加読み込みは2秒まで、全体10秒の枠を維持する。追加のVectorize検索・Embedding・reranking・Geminiは行わない。足りない属性の根拠をTop5の枠に優先して入れる。
4. 同一sourceIdで、全文の段落列が完全一致する参照だけ重複として減らす。別文書の同じ記述、異なる条件・値・数式・説明は保持する。語彙類似性による削除は行わない。
5. 初期の予算内参照でカバーしていた情報が失われるときは初期参照に戻す。fallbackにも5参照・24,000文字の本文予算を適用する。最終的に必要な具体的情報がそろわなければ、従来のinsufficient/通常AIチャットfallbackを維持する。

段落を積極的に短縮する案は独立レビューで、離れた位置にある「送料別途」「法人向け」「Price excludes shipping and tax.」を落とす問題が再現したため採用していない。全文保持と根拠位置の抽出を組み合わせる。

## 変更ファイル

既存変更:
- `mcp-server/src/rag/retrieval.js`: bounded reserve補充、原文根拠選択への接続。
- `mcp-server/src/rag/answerability.js`: 既存の具体的情報判定を`referenceSupport`として公開。判定ロジックは変更なし。
- `docs/HYBRID_RAG.md`: 実装と未検証範囲の説明。

新規:
- `mcp-server/src/rag/evidence-selection.js`
- `mcp-server/src/rag-evidence-selection.test.js`
- `mcp-server/scripts/rag-quality/evidence-selection-fixture.json`
- `mcp-server/scripts/rag-quality/evidence-selection-evaluate.mjs`
- この報告と`RAG_EVIDENCE_SELECTION_RESULTS.json`

D1 migration、binding、secret、iOSの変更、再Embeddingは不要。

## 検証

- 新規25回帰テスト成功。根拠補充、reranker障害、別ユーザー・folder/notebook/pageの範囲逸脱、削除中の参照、読み込み失敗/2秒停止、prompt injectionのJSON格納、出典page/chunk一致、RAG disabled、数式/否定/未知条件保持、24k上限を含む。
- 変更前retrievalへ同じ補充回帰テストを適用し、reranker正常/障害の2件とも`insufficient`で失敗。変更後は価格と型番を含む`grounded`で成功。
- 100ページの合成PDFテキストを10ページ×10batchで登録。型番が先頭5ページ、価格が6ページにある例でページ6と1を返すこと、再登録で追加Embeddingなし、別ユーザーは0件を確認。PDF読取/OCR・実Cloudflare・実Geminiの実験ではない。
- 関連テスト67/67成功。Worker全テスト864/864成功（43.708秒）。既存の登録・chunk overlap/page boundary・Hybrid/RRF・認可・Locked除外・account/source deletion・disabled fallback等の回帰も含む。今回の実装前は839件。
- 独立Code Reviewerで重要条件削除・補充fallback予算超過の2指摘を修正し、再レビューでblocking指摘なし。owner/scope/deletion条件と追加読み込み上限を確認。

## 合成質問16件の選択処理評価

固定の順位付き候補を入力して、変更前の先頭5件と変更後の選択処理を比較。追加候補は認可済みと仮定しており、検索・Geminiの回答自体は評価していない。

ラベルはエージェントが作成した暫定の合成正解。人間による確認は未実施。dev8件/holdout8件に分離したが、holdoutも同じ実装工程で作成しており、独立した盲検ではない。

| 選択処理の指標 | dev変更前→後 | holdout変更前→後 |
| --- | --- | --- |
| 正解として指定した事実が選択本文に含まれる割合 | 86.7%→93.3% | 88.2%→100% |
| 必要な事実が全部含まれるケース | 6/8→7/8 | 6/8→8/8 |
| 指定ページに基づくselector出典適合率（ケース平均） | 100%→100% | 87.5%→93.75% |
| 全文完全一致の重複参照数 | 7→0 | 11→0 |
| 選択本文の合計文字数 | 314→228 | 379→236 |
| 既存具体的属性gateの通過ケース | 6/8→7/8 | 6/8→7/8 |
| 追加モデル呼び出し | 0→0 | 0→0 |

これらは**選択処理の出力**指標であり、最終API出典・回答正答率・実サービス精度ではない。`conditions-year`は正解本文を補えるが、既存parserが先頭年指定の対象を正しく取り出せず属性gateを通らない。資料に価格が存在しないケースもfallbackのまま。事実の文字列存在は意味理解や条件の正しさを保証しない。

ローカルの選択処理時間は結果JSONに記録するが、短い合成本文の単発実行なのでCloudflareの遅延や本番容量計画には使えない。本文文字数にはJSON/evidenceSpansの付加情報を含めていない。請求額は未測定。reserveが動く場合、D1追加読み込みが最大5回発生する。

再実行:
```sh
cd mcp-server
node --test src/rag-evidence-selection.test.js
npm test
node scripts/rag-quality/evidence-selection-evaluate.mjs ../docs/RAG_EVIDENCE_SELECTION_RESULTS.json
```

## 安全・互換性・停止方法

- canonical sessionから生成するaccountKeyを継続使用。VectorizeのaccountKey filter、D1のowner/scope/ready/source/account deletion条件を継続。追加読み込みにも同じ条件を適用する。
- retrieved textはuntrusted JSON dataとして渡す。evidenceSpansは本文位置であり、命令・新規message roleではない。テストは境界を検証したもので、Geminiが全攻撃に耐えることの保証ではない。
- 本文/Embedding元/プロンプトのログを追加しない。新しい外部送信先・保存データ・権限はない。プライバシーポリシーの今回追加変更はなし。
- 出典APIはsourceId/title/pageNumber/chunkIdを保持。iOS導線の変更なし。今回iOS/実機テストは再実行していない。
- ロールバックは今回のretrieval呼び出し部分とanswerabilityのexportを元に戻し、新moduleを外す。DB/vectorデータ変更がないためデータ移行不要。障害時は既存RAG_ENABLED=falseで停止可能。
- stagingは前回の停止状態を維持し、今回deploy/secret変更/実資料外部送信なし。

## 残る作業

1. 合成ラベルを人間が確認し、独立した未見の代表質問・資料へ拡張する。
2. 先頭年指定など既存の対象解析、暗黙の対象/言い換え、判定できない複合・仕組み説明を評価する。今回の必要情報判定はルールベースで完全な意味解析ではない。
3. 同一ページ内の遠いchunkはreserve単位がpageであるため補えないことがある。言い換え重複・別sourceの重複も削除しない。
4. stagingで実Embedding/reranking/Geminiを通して、回答の事実・条件・出典を評価する。代表的実PDF/日本語OCRと実iPadの引用タップも再確認する。
5. 追加D1読み込みとprompt付加情報込みのp50/p95応答時間・請求/トークン量を実測する。

参考にした考え方: [Azure semantic captions](https://learn.microsoft.com/en-us/azure/search/semantic-search-overview)の原文根拠、[Dropbox Dashの評価](https://dropbox.tech/machine-learning/llm-human-labeling-improving-search-relevance-dropbox-dash)のラベル付き検証。実サービスと同等の学習済み選択モデル・人間ラベル・品質保証を実装したという意味ではない。

Projectの資料の更新が必要: [設計] `HYBRID_RAG.md`。Desktop複製は変更していない。
