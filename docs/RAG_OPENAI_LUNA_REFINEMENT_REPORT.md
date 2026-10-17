# Luna回答ルールの修正と実API再確認

2026-10-13、rag-wip上で固定policyのみ調整。iOS・検索・認証・クレジット・同意・binding・migration・公開flagsは変更していない。

## 修正

- source_only: 条件の整理は許可するが未記載の利用場面を設定しない。資料にある境界値で例を作ることも抑制。資料に実例がある場合と資料の値からの計算は許可する。
- explain: 資料外の具体例より前に仮定の例と表示。資料記載の実例は仮定と呼ばない。
- 数式: 名称から対象範囲を補完せず、資料の全記号・単位を保持。同じ記号を量から数値へ黙って再定義しない。
- 不足値: 数値が確定不能なら理由を述べて不要な代入式を追加しない。記号式/代入手順の明示依頼と、全値がある計算は維持。
- 出典: 実metadataでも引用表記を本文に生成せず、システムの構造化出典へ任せる。質問の対象名・内容上必要な番号は許可。

特定の質問の正答・固有値はpolicyへ入れていない。前版はprivate一時領域に保持し、必要なら当該policy変更だけを戻せる。

## 検証

対象39件、Worker全1,186件、独立関連46件成功、失敗/skip0。初回全体テストでは旧引用指示の文言一致1件が失敗。新しい本文引用禁止・捏造禁止の2assertへ更新し、24 golden casesの既存検証を保った上で全体を再実行した。差分チェック成功。iOS変更なしのため今回はiOSを再実行していない。

独立コードレビューHigh/Mediumなし。通常disabled/no-consent/no-hit/outageでは従来chatへのrequest・citations不変、insufficient/clarification保守policy不変、grounded/partialに到達、取得本文と構造化出典の一致を確認。モックはLLM遵守の証明ではない。

## 実Luna評価

固定合成予約/回路の各2styleを同じ順序で比較。02と03の計8API送信がHTTP200/completed、要求/返却gpt-6-luna。各対の入力・reference・設定・構造化出典は同一。ローカル合成検索であり実Cloudflare・実PDF/OCR/iPadではない。fixed probesのみmoderationを省略、本番は変更なし。

02: 回路の単位/適用範囲/代入/本文引用とexplain仮定表示は改善したが、予約source_onlyに未記載の例が残った。この結果を保持し境界値使用の例も禁止する一般指示を追加。

03: 4回答とも今回対象のmanual基準をCodexと独立AIレビューで満たした。source_onlyは条件のみ、explainは仮定表示と必要補足を維持、両方で未知値/例外を保持。全体Rの補完・不要代入・本文引用なし。電圧の説明は初心者向け近似として許容したが、厳密な電位差/エネルギー毎電荷の説明を評価したものではない。

固定2問各1回の最終結果であり、汎用精度や安定性・本番合格を主張しない。未使用問題、複数回、計算可能ケース・明示記号式依頼・資料実例・partial・prompt injectionの実回答確認を次に行う。

## 費用・保持

今回8送信: 入力21,746、出力2,675（思考1,397含む）、計24,421tokens。既確認Standard単価に基づく概算0.003512ドル、1ドル150円の仮定で0.53円。実請求/税/Cloudflare/OCRは未確認・含めない。

生の合成回答はprivate0700/0600のみ、repository/Notionへ本文やキーを保存しない。deploy/push/merge/commitなし。

変更ファイルはanswer-policy.js、rag-answer-style.test.js、rag-final-answer-evaluation.test.js。新規報告は本書とRAG_OPENAI_LUNA_REFINEMENT_RESULTS.json。

Projectの資料の更新: なし（既存設計内の回答ルール修正と評価報告）。
