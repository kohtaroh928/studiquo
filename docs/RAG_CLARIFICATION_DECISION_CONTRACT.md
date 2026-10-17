# 聞き返し評価の小契約 v1（fixture先行・runtime未接続）

2026-10-16。[設計](RAG_CLARIFICATION_DECISION_DESIGN.md)を具体化する別のoffline契約。既存v4 task-plan/status/実run/oracleを変更しない。以下はvalidator実装前の契約で、モデル品質や認可を保証するものではない。

## 入力と由来

質問ファイルの各caseは`{id,matrix,input,harness}`。id/matrix/harnessは評価用メタデータで、将来モデルへ渡すのはinputだけ。oracleは別ファイルに保存しrequest側からimportしない。

inputのexact fieldsは`version:1, mode, question, contextItems`。modeはquestion_only / contextual_pre_search / scoped_inspection。contextItemsは`{id,kind,availability,text,revision,scopeRef,outcome}`の配列で、kindはuser_history / scope_page / scope_notebook / scope_folder / scope_library / inspection。availabilityはavailable / unavailable、unavailableのtextは空。revisionはその項目の版（inspectionでは参照するscopeの版）、scopeRef/outcomeはinspection以外null。scope textは選択範囲の境界記述で本文ではない。questionは16KiB、context各8KiB、合計64KiB、context最大16を予定上限とする。切断で収めない。idはqを原質問の予約参照とし、contextはc1〜c16の一意ID。本文・名称は合成データのみ。

question_onlyはcontext空。contextual_pre_searchはinspectionを含めない。scoped_inspectionはscope項目とinspection項目を必要とするが、失効/取得不能の項目もtext空で表現可能。inspection.scopeRefは同じinputのscope IDを指しrevisionも一致する。outcomeはcontent / no_hits / failed / unavailable。contentは利用可能scope/inspectionと非空本文、no_hitsは利用可能scope/inspectionと空本文、failed/unavailableは利用不可inspectionと空本文。取得不能・失効scopeはavailability unavailable/text空で、内容由来として参照禁止。確認時点の版一致は実時間の認可を保証しない。historyは古い発言順に並ぶが、最後の名詞や発言だけで対象を確定できる契約ではない。

harnessは`{technicalState:ok|unsupported|failed}`。評価器/契約処理自体のテストfault条件でありモデルへ送らない。検索のfailed/no_hits/unavailableはinspection.outcomeで表す。検索障害でもtechnicalState okで原質問から解決済み対象を保持しevidence unavailableとできる。障害・表現不能をモデルの意味推定で認定したことにしない。inputの不正、上限超過、別hashは候補のclarifyではなく形式拒否。inputHashはJSON.stringify(input)のUTF8 SHA256。質問が同じでもcontext/modeが違えば別bindingとなる。

## 外部判定候補

ルートは`{version:1,inputHash,technicalState,decisions}`。technicalStateがunsupported/failedならdecisions空で、意味review母数には技術未評価として残す。意味不明・対象不明を技術失敗へすり替えない。技術状態の真偽も信頼できるharness/呼出元と別照合する。

okのdecisionsは1〜16件、各exact fieldsは次のとおり。

| field | 値 |
| --- | --- |
| id | d1〜d16、一意 |
| requestLabel | 何を求めているかの非空解釈ラベル、最大256UTF16 |
| requestRefs | [q]だけ。原質問にない要求を履歴だけから作らない |
| targetState | single / set / not_required / unresolved / uncertain |
| basis | question / history / selected_scope / inspection / none |
| targetRefs | qまたは実在する利用可能context ID、重複なし |
| evidenceState | not_checked / supported / insufficient / conflicting / no_hits / unavailable |
| nextAction | proceed / inspect_scope / clarify_target / review_required |
| inspectionPurpose | none / target / content |

refsは粗い由来参照で、引用や事実支持の証明ではない。targetの名称ラベルは今回は出力しない。正しいIDでも意味上対象を取り違え得るので、targetState/basis/requestLabel/全参照の意味を独立reviewで確認する。

## 組合せの形式制約

- single/setはbasisをquestion/history/selected_scope/inspectionのいずれかにし、targetRefs非空。not_requiredはbasis question・targetRefs=q。unresolved/uncertainはbasis none・targetRefs空。候補確認範囲はtargetRefsではなくinputとnextAction/inspectionPurposeに残す。
- basis questionはtargetRefs=q。historyはuser_historyの参照を少なくとも1件、selected_scopeはscope参照を少なくとも1件、inspectionはoutcome contentのinspectionと、そのscopeRefに一致するscopeの参照両方を必要とする。どれも利用可能なものだけ。補足q参照は許すが、異なるkindへ根拠をすり替えない。
- question_onlyはbasis question/noneだけ。pre_searchまでのevidenceStateはnot_checked固定。scoped_inspectionでも入力中にinspectionがあるだけでsupportedへ自動変換しない。
- proceedはsingle/set/not_required。clarify_targetはunresolved。review_requiredはuncertain。inspect_scopeはsingle/set/unresolvedで、少なくとも利用可能scopeが必要。対象解決済みの内容取得はpurpose content、未解決の候補確認はpurpose target。他のactionはpurpose none。
- scope指定だけでsingle/setの意味を証明しない。ページ全体の要約はselected_scope/setとして解決済みでも、内容取得前ならevidence not_checked・inspect_scope/content。曖昧な「これ」はunresolved・inspect_scope/targetとなり得る。
- 複合質問は要求ごとのdecisions。一つのunresolvedで他の解決済み要求を落とさない。全要求が正当に同じstateになる場合は形式拒否せず、一律状態による意味漏れかどうかは独立reviewで確認する。decision順序だけでoracleへ対応させず、独立意味reviewでrequestLabelと由来を照合する。

上記は必要条件で、質問の意味を自動判定する規則ではない。scopeに複数対象があるか、履歴が関連するか、evidenceが支持するかはvalidatorだけで確定しない。既存accountKey/locked/削除/認可再確認は将来呼出元が維持し、合成availabilityは実認可の代替にしない。

proceedは対象処理を継続できるというラベルで、回答可能・資料支持・実行権限の保証ではない。uncertain/review_requiredは意味上の安全な保留先だが、現在の30caseには意味上の正例を含めていない。この不足を成功率や形式テストで隠さず、次のvalidatorで形式上の正例と矛盾組合せの拒否を確認し、意味正例は別途独立注釈する。

## oracleと評価

別ファイルの各caseはid/inputHash/requirements。requirementはr1〜r16、requestLabel、許容する判定tuple（targetState/basis/evidenceState/nextAction/inspectionPurpose）、必須由来、理由を持つ。許容tupleは代替を入れれば安全になるのではなく、判断が未確定ならoracle自体をpendingにして独立確認する。humanGoldReviewはpending。case数とmatrix行数を区別する。

独立reviewは要求対応、対象の必要性/単数集合、履歴/範囲の由来、聞返しaction、根拠状態の分離、非捏造/非命令実行、部分要求保持を確認する予定。未review/不確実/技術失敗/表現不能を成功分母から隠さない。形式成功・oracle fixture整合・モデル意味適合は別報告。

今回のfixtureは新しい合成開発例だけで、旧12問/未使用20問を転用しない。prompt・モデル送信・runtime接続はない。小契約とfixtureの独立確認後にのみpure validatorと意味review集計を実装する。Projectの資料の更新: なし。

## 注釈確認

独立Plannerで小契約と30case/29意味要求/2評価器fault/22matrixを確認。複数講座の料金一覧とも読める問いを単数対象と断定していたMediumを修正し、「ユーザーが選んだ1講座」を尋ねるが選択情報は未提供という明確な境界へした。inputHashと根拠を更新し、正解を広げて通してはいない。最終High/Medium残件なし。oracleのannotationReview/humanGoldReviewはファイル内ではpendingのまま、独立確認の根拠はこの文書と結果JSONへ別記する。人間gold確認済みとは主張しない。

## 今回の検証結果

別々のinput/oracle JSONとfixture整合テストを追加した。対象8件、修正後の全Worker1,667件が成功（失敗/skip0）。独立コード/安全レビューも最終8件を実行成功、High/Medium残件なし。整合テストはinputHash/mode/context版・scope対応、本文非露出、期待tupleの型/phase/由来、部分要求、pageの内容取得と対象未解決の区別、評価器faultと検索失敗の分離を確認する。

これらはfixtureの整合性テストで、判定validator・意味review集計・実モデル・実認可・prompt injection耐性の実証ではない。次はpure validatorの入力/出力上限・不正参照/別scope/版違い/失効参照/矛盾tuple/不確実正例の回帰を実装する。外部意味reviewの集計はその後。今回API送信/キー読取0、旧source/完了run/4監査artifact・旧5停止lockを保持した。[結果JSON](RAG_CLARIFICATION_FIXTURE_RESULTS.json)参照。Projectの資料の更新: なし。
