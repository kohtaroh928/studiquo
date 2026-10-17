# 対象role保持の修正候補：比較入力の準備

2026-10-16。[実評価のrole欠落](RAG_UNIT_PLANNER_API_RUN_REPORT.md)を受けて、別の合成開発問題とoracleを先に用意し独立確認後に、通信なしの比較requestを実装した。実モデルへの追加送信はない。

## 変更範囲

- 新質問12問/14要求、うち10問は複数unit。全7operation、対象不在2問、背景名詞・対象と条件の役割・複数対象/別属性を含む。[oracle草案と制限](RAG_SUBJECT_ROLE_ORACLE_DRAFT.md)参照。
- `subject-role-task-planner-request.mjs`は質問ファイルだけを読み、oracle/reviewをimportしない。固定indexとbaseline/candidateだけを受け付ける。
- baselineは凍結v4の指示をそのまま使う。candidateは明示対象のsubjects保持・条件対象と適用状況の区別・背景/供給値の無差別な対象化禁止・対象不在での捏造禁止の4規則だけを追加する。属性ラベルに対象が含まれても構造化roleの代わりにしない。
- 両版の質問/hash/unit、v4 schema、Luna/medium/default/store:false/stream:false/max_output8192は同一。24bodyのhashをmanifestで追跡し、32KiB上限・固定selector・fresh cloneを確認する。
- 旧v4 request/source/実runを変更せず、出力schemaもv4のまま。新12問を旧8問用のparser/runnerへそのまま流す経路は作らない。

## 検証と限界

対象8件成功。独立oracle確認でHigh/Medium相当の注釈矛盾なし、独立コード確認でも対象8成功/High・Mediumなし。全Worker1,548件成功、失敗/skip 0。[結果JSON](RAG_SUBJECT_ROLE_CANDIDATE_RESULTS.json)へsource hashと比較manifestを固定した。

これらはデータ整合性・入力差分・形式の確認であり、対象抽出の精度改善を示していない。人間gold確認はpending。計算operandが元質問/provenanceに残ることと、operandの意味・taskへの参照を理解して保持することを区別し、後者は今回のoracle対象外とする。

次は固定12問×2variant用の応答bindingと、比較の有限予算/段階review/停止条件を別設計へ具体化する。旧5runのlockを解除せず、停止した実runを再利用しない。未使用20問は調整に使わない。実API・キー読取0、本番v1は維持。

参考：[OpenAI Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=responses)のobject必須/追加field禁止等を再確認し、既存v4 local validatorと形式を維持した。新12問schemaの実API受理は未確認。

Projectの資料の更新: なし。
