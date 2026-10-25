# TaskPlan v2: 評価用の要求分解契約

2026-10-15。初版の操作タグ区分の曖昧さを整理する小単位。**規約・schema・oracleの整合を検証した段階であり、モデルが質問から抽出できたという結果ではない。** runtimeのv1、初版の質問/タグ/code/hash/結果、既存bank/未使用20問は保持。

## 規約

| 操作 | 意味 |
| --- | --- |
| value | 値・日付・名称・可否などの回答要求。取得か導出かを質問だけで確定しない |
| explain | 用語・式・関係・方法などの説明要求。「比較方法を説明」は、それだけでは比較の実行要求でない |
| calculate | 明示された計算・導出の要求 |
| compare | 指定された属性について対象間の関係を示す要求。比較できるという許可ではない |
| recommend | 選択・推薦の要求。選択に必要な根拠があるという認定ではない |
| conditions | 適用条件・例外などを答える要求 |
| summarize | 指定範囲を要約する要求 |

1 taskは操作と回答対象属性のscope。単一の真偽命題とは限らない。説明で式/記号/概念を求める場合は同じexplainでも別scopeを保持する。AとBの一つの属性を比較する要求は、両対象を持つ1scope。比較を対象ごとに二重計上しない。

値を問う場合の`resolution`はunknown。根拠支持と比較許可もunknown固定。質問中の数値・条件は要求条件として保持できるが、資料の値や成立条件の証明に読み替えない。計画を作ることと、検索根拠で答えられることは別である。

未解決の指示語はreferenceの曖昧さ、操作の解釈の幅はoperation、未知の構文はsyntaxへ区別する。資料支持が不明なだけで対象の確認質問へ置き換えない。rootのneeds_clarificationはreference spanが必要で、部分的に明示されたtaskとの共存を許す。unrecognizedはtaskなし・未解決spanあり。candidateは1task以上が必要だが、完全性の認定ではない。

## 形式と検証

`scripts/rag-quality/task-plan-v2.mjs` がJSON schema、形式検証器、oracleとの注釈比較を提供する。

- 最大16task、対象/状況/request spanは各最大4、未解決項目8、質問16KiB、plan32KiB。全フィールドを定義し、余剰field/不明enum/支持・許可の偽装を拒否する。
- 各taskはid/operation/attribute/subjects/conditions/requestSpansと3つのunknown固定値。attribute・対象・状況・依頼箇所は原質問のUTF-16 start/end/text。空・範囲外・改変引用・重複id・同role内の重複spanを拒否する。
- JSON schemaだけでは表せないoffset整合やroot status間の条件はvalidatorで確認する。schemaの合格だけで検証済みとしない。
- 形式検証は意味検証ではない。広いattribute span、曖昧な対象対応、欠落task、引用中の偽命令等を理解できたことを保証しない。任意のtask実行や外部送信はしない。
- oracle比較は、許容操作・属性span・対象span集合・状況span集合・依頼箇所span集合を使う厳密な注釈対応。1candidateは最大1oracle項目へ対応し、重複/結合で複数要求を埋めない。missing/extraを返す。span一致は意味一致の十分条件でなく、別の妥当なspanでも不一致となり得るため独立意味レビューが必要。
- `semanticCompleteness`はpending、`evidenceSupport`はunknown、`releaseAccepted`はfalse。モデルのcovered ID自己申告を完了判定に使わない。

## oracle v2

`task-plan-oracle-v2.mjs` は初版と同じ6質問を別定義で扱う。16scopeになったが、16へ合わせることを受入条件にはしていない。元タグは変更しない。

- 「密度の式・各記号の意味・体積と質量の関係」は説明対象を3scopeへ分け、全てexplainとする。式があるから別lookupを必須にしない。
- 明示の税抜計算はcalculate。「送料も含めた最終支払額はいくら」はvalue/calculateの複数解釈を事前に許容し、取得手段はunknownのまま。
- 対象名がある比較では両対象を保持し、「急ぐ場合」「税抜」「職員変更時」などを状況の別spanにする。
- これらは手書きの規約例で、人間確認pending。正解値・資料本文・評価case IDを質問plannerへ渡す実装はない。gold生成を抽出精度と呼ばない。

`RAG_TASK_PLAN_V2_CONTRACT_RESULTS.json`はschema/oracle/sourceのhashと整合確認を記録する。実際の抽出結果ではなく、modelEvaluated=false。初版の不一致2件や誤検出の報告は上書きしない。

## 受入と次の実装単位

今段階は規約、schema、拒否/欠落/重複/対象/条件の検証、oracleとの整合、独立レビューまで。次は**評価環境だけ**で、質問のみを渡す構造化planner requestを作り、Lunaの出力をこのvalidator/人手oracle/独立意味レビューで比較する。

その際、gold/期待ラベル/正解値をrequestへ混ぜず、質問内のメタ命令は削除して別質問にせず未信頼データとして保持するか送信前保留の契約を決める。固定合成質問、呼出数・token・費用上限、先行journal、初失敗停止、秘密/本文非ログを維持し、実API前に独立安全レビューする。本番への組込み、追加分類APIの常時使用、回答の自動修正、生成後validator導入は別判断であり今回行わない。

## 実行記録

対象7テスト・関連27テスト・Worker全1,328テスト成功（失敗/skip0）。独立対象7テスト成功、新たなHigh/Medium指摘なし。レビューで見つかった依頼spanの照合漏れと学生料金条件の対象対応を修正し、反例を回帰テストへ追加した。旧初版hash/rubric/過去報告は不変、runtime出力変更0。追加API0、iOS未変更/未再実行。deploy/push/merge/commit/migration適用/secret変更なし。

Projectの資料の更新: なし（評価専用の契約と候補準備で、採用済み構成・公開状態は不変）。
