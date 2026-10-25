# 対象role保持：次の開発問題とoracle草案

2026-10-16。既存v4実runの1問でsubjects構造化漏れが見つかったため、prompt修正前に別題の開発問題を固定する。12問/14要求、全て合成。既存8問や未使用20問を変更・再利用せず、実APIへ未送信。本番v1/停止した5runを保持する。

## 分離と評価規約

- `role-preservation-questions-v1.json`：id/questionだけのcaseと出自metadata。将来のrequestが使えるのはこちらだけ。
- `role-preservation-oracle-v1.json`：同じcaseの原子的要求、代表span、operation、attribute、subjects、conditions。質問ファイルhashへbindし、モデル入力へ渡さない。
- 人間による確認はpending。独立エージェントの意味/役割確認は人間gold確定を代替しない。元span完全一致は注釈照合であり、意味評価は従来8観点を維持する。
- oracleの独立確認後、通信なしのbaseline/candidate request factoryを追加した。新runは作らず、出力schemaはv4を維持してprompt policyだけを別candidate/version/manifestへ分離する。

## 12問の狙い（idのみ）

| case id末尾 | 確認する能力 |
| --- | --- |
| concept-conditions | 対象概念が属性句に含まれていてもsubjectsを保持、独立条件/例外を2要求に分ける |
| qualified-concept | 対象を前文から参照し、申請状況をsubjectsでなくconditionsへ区別 |
| explain-across-units | 前文の明示対象について後文で方法を説明、1要求 |
| separate-attributes | 2対象/別属性の2要求を対応させ、各taskへ全名詞を混入しない |
| compare-with-condition | 比較1要求に両対象を保持し、環境をconditionsとして保持 |
| calculate-with-operands | 計算1要求と対象を保持、入力/出力/数値をsubjectsや適用条件へ誤分類しない |
| recommend-with-distractors | 候補2対象と適用条件を保持、背景の受付/筆記用具等をsubjectsへ加えない |
| joint-summary | 2資料の共同要約を1要求に保つ |
| unnamed-target | 属性は明示・対象名は未指定でsubjectsを捏造しない |
| explicitly-unnamed | 対象名なしの前文を尊重し、後文の属性要求を保持 |
| operation-word-in-name | 対象名中の「比較」を比較要求へ変えない |
| background-not-target | 背景の例と質問対象を区別し、別文/別unitの対象・属性を対応 |

12問中10問が2〜3unit。7種のoperationとsubjects空の2ケースを含む。unitは構造参照であり意味の原子ではない。代表oracleの単一spanからunitを作れることだけで、実モデルの参照選択を検証したとはしない。

対象未指定ケースは「質問から抽出できる属性の保持・対象非捏造」を評価する。実際に値を回答できるか/追加質問が必要かはevidence/resolution unknownの後段判断であり、今回のoracleは答えを確定しない。計算の数値は原質問のprovenanceに残り、計算結果や演算子を回答として出させない。

## 受け入れ条件と次

質問/oracleのcase順・id・hash・代表spanが整合すること、単一taskが独立2要求へ二重計上されないこと、対象あり/なしと全operationの範囲を確認する。対象・条件が別文にある代表を含め、誤roleは形式検証で合格し得ることと意味評価の必要性を残す。データ2ファイルと整合性/代表schemaテストを先に準備し、独立確認後に別request factoryと差分テストを追加した。既存runtime/request/runner/料金/secretは変更しない。

独立確認で曖昧さがあれば、モデルを試す前に草案を直して差分を残す。凍結hashは最終結果に記録する。API/キー読取0、モデル品質未評価。Projectの資料の更新: なし。

独立oracle確認：High/Mediumの注釈矛盾なし。12問/14要求・10multiunit・subjects空2問・全7operation・hash/span整合を確認した。人間goldはpending。計算operandは原文に残るだけで、数値の意味理解やtaskへの参照対応はこのoracleでは評価できない。
