# 聞き返し判定のpure形式validator

2026-10-16。[小契約](RAG_CLARIFICATION_DECISION_CONTRACT.md)に従い、`clarification-decision.mjs`を別評価moduleとして追加した。runtime・prompt・既存fixture/oracle・完了runは変更していない。通信・ファイル読取・oracle import・key loader・ログ出力を持たない。

## 入力と検証

`clarificationInputBinding(rawInput)`はJSON文字列だけを受け、inputの形・phase・contextを確認してinputとinputHashを返す。hashはJSON.stringify(parsed input)のUTF8 SHA256。改行・空白の異なるJSON表現は同じbindingになるが、key順序を正規化した同値保証や、上流送信の証明ではない。questionだけでなくmode/context/版/結果状態もbindする。

`validateClarificationDecision(rawInput, rawDecision)`は、input bindingと出力のexact keys・型・列挙値・件数・参照・状態の組合せを確認する。呼出元のオブジェクト/getter等は受けず、raw JSONをparseする。入力64KiB/質問16KiB/context各8KiB・16件、出力32KiB/decision16件/ラベル256UTF16/targetRefs最大17、revision64UTF16を上限にし、切断や正規化で救済しない。不正は固定error codeで拒否し、本文をerrorへ混ぜない。

contextのinspectionは、同一input内のscopeRefとrevisionへ対応付け、outcome/availability/空本文の整合を確認する。content/no_hitsには利用可能scopeが必要、失効/failed/unavailableは本文を持たず、targetRefsから利用不可項目を参照できない。参照kindはbasisごとの許可集合に限定し、inspectionとその対応scopeを両方参照する。別scopeを代用・追加して根拠を混ぜる形も拒否する。

対象状態とproceed/inspect_scope/clarify_target/review_required、content/target目的、phaseとevidenceの整合を検査する。未確認段階のsupported、観測なしno_hits等を拒否する。観測の存在は意味的支持の必要条件に留まり、別対象のcontentを本当の根拠として支持しているかは独立意味reviewが必要。

## 保留を維持する境界

戻り値はsemantics=pending、technicalStateVerified=false、authorizationVerified=false、releaseAccepted=false。unsupported/failedの自己申告は空decisionという形だけを検査し、真偽は後のtrusted harness照合へ残す。検索障害でもtechnicalState=okのまま既知対象とevidence unavailableを保持できる。実認可・locked除外・注入耐性はこれだけでは実証しない。

部分要求の異なる状態、正当に同じ状態が続く複数decision、uncertain/review_requiredの形式上の正例を許す。一方、正しい参照付きの架空ラベル、要求の欠落、観測があるだけの誤ったsupportedは形式上通り得る反例としてテストに残した。これらを意味適合へ昇格させない。uncertainの実モデル意味正例はまだ未評価。

## 検証と次の作業

新規13回帰で、全30fixtureの形式roundtrip・全文脈binding・Unicode/byte/件数・extra fields・別scope/版・失効本文・phase/evidence・由来kind・page内容取得/対象確認・保留・部分要求・技術状態・意味限界を確認した。対象13成功、独立契約レビュー13成功、独立コード/安全レビューはfixture8を含む21成功、High/Medium残件なし。全Workerの結果は[結果JSON](RAG_CLARIFICATION_VALIDATOR_RESULTS.json)参照。

旧fixtureと小契約の保存hash、現source closure、完了61行run/4監査artifact、旧5停止lockの不変を照合した。API送信・キー読取0。本番v1、RAG flag、未使用20問、DB/設定は不変。rollbackは新moduleを呼ばないこと。

次は、外部意味reviewをinput/decision/oracleへbindして集計し、要求の取り違え・欠落・余分な確認・聞き返し漏れ・技術状態不一致を保留込みで数える。oracleをrequestへ渡さず、harnessとの照合を形式validatorの成功とは区別する。新candidate prompt/有料評価/runtime採用は後工程。今回のテスト成功はモデル品質改善の証拠ではない。Projectの資料の更新: なし。
