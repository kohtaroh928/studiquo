# Unit参照TaskPlan v4：評価専用schema/validator

2026-10-15。[候補設計](RAG_QUESTION_UNIT_PLAN_DESIGN.md)の次単位。Standardのオフライン実装とし、旧v2/v3・既存run・本番を変更しない。

## 固定する契約

- 質問から[unit前処理](RAG_QUESTION_UNITS_CONTRACT.md)を再実行し、client/model指定のunit一覧や位置を信用しない。schemaはquestionHash単一enumと既知ID enumを持つ。
- rootはversion=4/questionHash/status/tasks/unresolvedだけ。statusはcandidate/needs_clarification/unrecognized。tasks最大16、unresolved最大8。
- taskはid/operation/attribute/subjects/conditions/requestUnitIds/resolution/evidenceSupport/comparisonPermission。idはt1..t16で重複不可、operationは既存7種類。3つの支持/許可値はunknownのみ。
- attributeは `{label,unitIds}`、subjects/conditionsはその配列（各最大4、空可）。labelは非空白・妥当なUnicode scalar・最大256 UTF16、trim/正規化せず原文引用と名乗らない。まったく同じlabelと同じ参照集合のrole要素の重複は拒否する。
- 各unitIds/requestUnitIdsは1..その質問のunit数（最大64）で、既知IDのみ・重複不可。参照4個の案はここで置換し、5unit以上に分散する要求も表現できるようにする。同じunitを複数task/roleで参照でき、一つのtaskは複数unitを参照できる。参照順は意味合格条件にしない。
- unresolvedはkind(reference/operation/syntax)とunitIds。必須参照は空不可。referenceがあればneeds_clarificationを必須とし、その逆も必須。candidateにはtask、unrecognizedにはtaskなし+unresolvedを必須にする。schemaは各enum/形を示し、cross-field制約・Unicode・重複はlocal validatorで必ず検証する。
- validatorのplan入力はJSON文字列のみ。先に最大32768 UTF8 byteを確認してparseし、任意object/Proxy/getter/循環を受け付けない。exact keys/型/件数/ラベル/参照/hash/statusを検証し、旧planへfallback/変換しない。

## 戻り値と限界

planと、questionHash/原文unit一覧を一度だけ持つstructuralProvenanceを返す。roleごとに原文を複写せず、roleはIDでこの表を参照する。全戻り値JSON最大256KiBも確認する。semanticCompleteness=pending/evidenceSupport=unknown/releaseAccepted=falseを維持し、planラベルを確認済み事実へ昇格しない。

質問入力不正、unit上限、plan入力/size/件数上限、JSON/形不正、hash不一致、label/参照不正、status矛盾を固定errorで区別し、本文や例外causeを含めない。上限で表現できないケースは、要求漏れや意味不明と自動同一視しない。32KiBやtask/subject/condition数の上限は残るため、表現不能の評価は別に記録する。local validatorだけで不足した参照や要求の意味を推定できるとはしない。

## 検証と次の段階

一unit二task・多unit一task・5以上/64参照・別質問hash・未知/重複ID・unknown偽装・status矛盾・byte/文字上限・戻り値独立性・不正Unicode/非JSON入力をテストする。正しいIDでも架空labelやrole取り違えが形式上通る負例を残す。既存開発問題は位置/形式互換の確認に限定し、モデルにoracleを渡さない。

独立設計確認後に新module/テストを追加し、独立コードレビューを通過した。全Workerの最終結果を後記する。request/response/実モデル評価は次の別単位。API/キー/本番接続0、未使用20問は凍結。Projectの資料の更新: なし。


## レビュー・進捗

専用14テスト・独立コード14成功、未解決High/Mediumなし。Lowの上限成功/拒否（task16・role4・unresolved8/9）は追加確認した。最終全Worker結果を追記する。今回API/キー読取0、v4 request/responseやモデル品質の確認は未実施。


## 最終確認

専用14・全Worker1,450成功（失敗/skip0、49.2秒）、独立コード14成功、未解決High/Mediumなし。ログ `/private/tmp/studiquo-unit-plan-v4-all.log`、本文なし結果 [RAG_UNIT_TASK_PLAN_V4_RESULTS.json](RAG_UNIT_TASK_PLAN_V4_RESULTS.json)。追加上限確認は対象テストでも再実行した。凍結source hashと4失敗run lock保持、構文/差分を確認。iOS/実モデルは今回未実施。
