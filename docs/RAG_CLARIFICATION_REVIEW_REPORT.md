# 聞き返しの過不足：外部意味review集計

2026-10-16。手動の再開指示により、`clarification-semantic-review.mjs`を追加した。自動実行設定は停止のまま。新moduleは既存pure validatorを使い、外部reviewの集計だけを行う。意味推測・モデル呼出・ファイル保存・key読取・oracleファイルのimportはない。

## bindingと対象

`clarificationReviewBinding(rawInput, rawDecision, rawOracle)`でinputHash/decisionHash/oracleHashを固定する。`evaluateClarificationReview(..., rawReview)`は、この3hashと一致する元reviewだけを受ける。1caseのoracleは64KiB、reviewは256KiB以内。decision/requirementは各最大16、対応候補は最大256組。元のinput/decisionは前工程の構造validatorで検査する。

oracleの許容tuple/必須参照は構造的に検査し、外部reviewがそれと矛盾する全passを提出した場合は拒否する。requestLabelの意味対応は文字列一致で自動採点しない。8観点はrequest/target/basis/action/evidence/provenance/intent/noInventedDetailsで、pass/fail/uncertainを受ける。

## 数え方

- 最大一対一matchingで、同じdecisionを複数要求の充足へ二重計上しない。候補が重なる場合は再割当する。
- 承認matchingと可能matchingからmissing/extraの上下限を返す。未review・不確実・unsupportedを成功母数から除外しない。
- 別のdecision単位actionAssessmentとしてappropriate/unnecessary_clarification/missed_clarification/uncertainを受ける。確定提出分だけを数え、未提出と不確実を別件数へ残す。
- 実際にはclarifyしていないdecisionを「余分な聞き返し」、clarify済みを「聞き返し漏れ」とする機械的矛盾を拒否。承認された全pass対応と過不足の判定が矛盾する場合も拒否する。
- 全failまで確定採点した不適合はreviewComplete=trueになれる。採点完了とreviewed_matchは別である。完全matching成立時は、意味上不要な全交差pairの採点を必須にしない。
- expected technicalStateと候補の不一致はtechnical_mismatch。一致してもnon-okはtechnical_unassessedであり、要求/decisionが0でも意味合格にはならない。

過不足は外部判定を集計した件数であり、自動的に正しさを保証する指標ではない。harnessStateMatchedは与えられたoracleとの一致だけで、harnessAuthenticated/reviewerAuthenticated/humanGoldVerified/releaseAcceptedはfalse。artifactHashも形式検査だけで、元監査文書の実在や独立性は確認しない。実接続時に呼出元が元文書・元reviewと照合・保持する必要がある。

## 検証と限界

13回帰で、30合成fixtureの集計roundtrip、review未提出、3hash取り違え、順序非依存、確定不適合の採点完了、uncertain/unsupported、二重計上/再割当、tuple/参照/過不足矛盾、technical mismatch/未評価、不正/重複/過大reviewを確認した。外部reviewはテスト内で生成した合成判定であり、実モデルを独立意味評価した結果ではない。

対象最終13成功、独立契約13・独立コード安全13成功。安全側では追加前に関連33件も成功。High/Medium残件なし。全Worker最終結果は[結果JSON](RAG_CLARIFICATION_REVIEW_RESULTS.json)参照。前工程のvalidator/fixture、小契約・完了run・旧停止runを変更していない。本番prompt/feature flag/DB/API互換性に影響なし。rollbackは新moduleを呼ばないこと。

次はこの評価入力契約に沿って、gold/harness/reviewを送信本文へ混ぜない候補requestと出力schemaを別に作る。モデルの聞き返し精度・人間gold・実認可・検索/回答全体の品質は未評価で、新有料run/runtime採用は後gate。今回API送信/キー読取0。Projectの資料の更新: なし。
