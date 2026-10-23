# 複数段落・片側不足の比較・必要背景説明の新規評価

2026-10-13。回答policyは変えず、新しい固定合成3問を2style×2回、計12実Luna回答で評価。資料・問題を新規作成したtransfer probeで盲検ではない。

## 実行方法

production handleAI + fixed local synthetic retrieval + real OpenAI。最大3case/6dispatchのrunを2回。元default2case/6dispatch/timeout/最初の失敗停止/秘密非表示は保持。各対input/reference/config/citations一致、12HTTP200/completed、要求/返却Luna、本人1ページ出典を確認。固定合成のみmoderation省略、本番は変更なし。

対象37件、全Worker1,218件、独立37件成功。失敗/skip0、差分チェック成功。partialをlearning probeへ初追加したため、manual prompt testで両styleを全文同一とする旧else分岐を修正。grounded同様、style指示以外のreference/query尾部が完全一致する検証へ変更し、採点rubricの非送信等は維持。独立レビューHigh/Mediumなし。

## 内容確認

Codexと独立AIによる確認で、主要な事実・計算・条件は良好。意味の機械checkはnot_configuredのまま、人間の教師レビューではない。

| 新規問題 | 観測 |
| --- | --- |
| 搬送、同ページの複数段落 | 4回答とも15 mを計算し、式/全単位/同じ向き・一定の速さ・速さ変化時の例外を保持。2回目sourceの例外の言い換えは少し曖昧だが結論は妥当 |
| 架空計器の片側不足比較 | 4回答とも未知相手の仕様を作らず完全比較と選択不能を明示。1回目explainに補足表示のない一般選択助言・条件付き既知計器の候補提案が残る |
| 密度、既知値の計算と基本説明 | 4回答とも2 g/cm³を計算し質量/体積/単位を正しく対応。explain2回答で必要背景を先に補足表示。3回答に未依頼の適用条件/例外の記載なしが残る |

比較の条件付き候補提案は、既知の使用条件に基づく提案であり、未知相手の仕様捏造や優劣の断定ではない。partialで何を提案できるかと補足表示の境界を次の調整対象にする。

source_onlyの密度を質量÷体積、単位を1cm³あたりgと言い換える説明は、資料の式/単位から直接導ける説明として許容。一般知識の追加と自動的に同一視して拒否しない。学習向けのわかりやすさを損なう制約へ変えない。

12回答の主要内容が良好でもstrictstyle全品質合格や汎用精度を主張しない。固定3問各2回・同順序であり、blindholdout/順序効果/一般再現性・実検索品質の証明ではない。

## 費用・保存

入力35,950/出力3,977（思考2,057含む）/合計39,927tokens。上流3.415〜8.115秒、平均4.795秒。既確認単価で概算0.0055835ドル、1ドル150円仮定で約0.84円。確定請求/税/Cloudflare/OCR費用は含めない。

実Cloudflare検索・実PDF/OCR/iPadではない。生の合成回答はprivate0700/0600のみ、repo/Notionへ本文/秘密は保存しない。

## 変更と残件

変更: learning-fixture.mjs（新3問）、learning-openai-live.mjs（固定catalog）、rag-learning-openai-live.test.js（pairedの新case）、rag-answer-style.test.js（partial prompt比較）。新規: 本書、RAG_BREADTH_EVALUATION_RESULTS.json。

productionpolicy/検索/認証/credits/同意/iOS/DB/flags/公開は変更なし。iOS再実行なし、deploy/push/merge/commitなし。

次はpartial回答の一般助言の区別と、未記載条件の不要な列挙を抑制する。式の既知条件保持・未知条件の推定禁止・資料からの計算/直接言い換えは維持し、今回3問と異なる問題で確認する。50問・他モデル・実資料/実iPadは別工程。

Projectの資料の更新: なし（評価の拡張と結果記録）。
