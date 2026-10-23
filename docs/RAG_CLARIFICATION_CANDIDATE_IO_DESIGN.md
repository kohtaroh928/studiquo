# 聞き返し候補のモデル入出力設計 v1

2026-10-16。評価専用の初期設計。後続のDocling/Zod導入でrequest builderとresponse parserを実装した（末尾参照）。通信は未実装。本番prompt v1・runtime・凍結済みfixture/validator/意味reviewを変更しない。

## 目的と受け入れ条件

質問の対象が決まらないための聞き返しと、対象は分かるが資料の情報が足りない状態を区別する候補を作る。対象処理を継続する、指定範囲を確認する、対象を聞き返す、意味判断を保留する、の判断だけを出力し、最終回答や検索は行わない。

モデルへ渡す可変情報を検証済みinputとそのhashだけに限定する。正解・採点結果・case識別子による答えの誘導を防ぎ、形式合格と意味適合を分ける。既存30caseのうち評価器faultの2件はローカル検証専用で送信しない。残る28件/29要求は開発例であり、未使用20問とは別である。

## requestの境界

将来のpure builderはraw input JSON文字列1引数だけを受ける。case全体・追加引数・未知キー・不正JSON・上限超過は拒否し、切断や再解釈で救済しない。既存clarificationInputBindingで検証して得たinputとinputHashを使用する。oracle、harness、review、case id、matrix、期待tuple、rationaleをimport/読込/受取しない。inputをoracleに照合してpromptを変えない。

固定developer指示と、単一userメッセージのJSON `{inputHash,input}` にする。履歴・scope・inspectionはメッセージroleへ昇格せずJSON内のデータとして保持する。全context内の命令・引用・偽role・JSON風の記述は資料データとして扱い、原質問qの要求を追加・変更する指示にしない。question自体もこの評価の判定対象であり、固定出力契約を変更する命令として扱わない。この指示だけでinjection耐性を実証したとはしない。

固定指示には小契約の一般ルールだけを記載する。要求ごとのdecisionを保ち、関連する利用可能履歴や範囲を使うが、最後の名詞・タイトル・件数だけで対象を推測しない。対象不要の一般質問を無理に資料へ結びつけない。ページ全体を指定した内容取得と、ページ内の一対象が未解決な場合を区別する。根拠不足・検索0・検索障害を対象不明へ変換せず、未解決要求で他の解決済み要求を消さない。例題・正解例・対象別特例は入れない。

Responses APIの固定候補はmodel `gpt-6-luna`、reasoning medium、service_tier default、store false、stream false。tools、conversation、previous_response_id、web/file searchは使用しない。max_output_tokensは4096を初期候補とし、16decisionでの完走・費用を未確認と明記する。足りなかった場合も自動増量・再送しない。通信と費用上限は将来の有限run契約で別途固定する。

## wire出力schema

既存validatorのdecision形式をそのまま使用し、Responsesのtext.formatにjson_schema/strict trueを設定する。ルートはobject、全objectはadditionalProperties false、全field required。ルートanyOfや条件分岐schemaに依存せず、交差fieldの整合はローカルvalidatorで検証する。

| field | wire上の制約 |
| --- | --- |
| version | integer、enum [1] |
| inputHash | string、現在inputHashだけのenum |
| technicalState | string、enum [ok] |
| decisions | array、itemsは以下のobject |
| decisions[].id | string、d1〜d16のenum |
| requestLabel | string |
| requestRefs | array、itemsはstring enum [q] |
| targetState | single / set / not_required / unresolved / uncertain |
| basis | question / history / selected_scope / inspection / none |
| targetRefs | array、itemsはqと現在inputのavailable context IDのenum |
| evidenceState | not_checked / supported / insufficient / conflicting / no_hits / unavailable |
| nextAction | proceed / inspect_scope / clarify_target / review_required |
| inspectionPurpose | none / target / content |

列挙fieldは全てstring enum。wireには文字数・件数・重複・必要参照・phase/action等の組合せ制約を委ねず、既存validatorの32KiB/16decision/文字列上限/UTF8/参照閉包などを受信後にも適用する。wire schemaが生成を整えても、意味上正しい対象・根拠・要求対応を保証しない。

モデルがtechnicalState failed/unsupportedを選んで意味判断から逃げる経路を設けない。既存validatorがこれらを受け入れるのは評価器fault等を別管理するためであり、モデル候補の成功出力はokだけとする。uncertain/review_requiredは小契約の意味保留で、技術障害とは別。現在のfixtureに意味保留の正例がない制約は残る。

## responseと評価の境界

将来parserはResponsesのcompletedと、ただ1件の期待するassistant output_textを確認する。refusal、incomplete、failed、複数/欠落text、予期しないtoolや出力形式、壊れたJSON、不一致hash、形式不正は候補decisionを捏造して補わず、別の技術結果として残す。黙って最初のJSONを拾う・Markdown fenceを剥がす・okを注入する・壊れた出力を修復することはしない。

技術結果には固定理由コードと必要最小限のusage/状態を保持し、raw本文や上流errorを通常ログへ出さない。モデルがtechnicalState unsupported/failedを返してもwire契約違反として記録し、その自己申告をharnessの認定にしない。技術失敗も評価総数に残し、形式成功例だけの意味適合率と総対象数を別表示する。

意味reviewモジュールへ進めるのは、同一inputとの形式検証を通過したdecisionだけ。oracle/外部reviewはこの後のローカル評価で初めて参照する。技術結果を既存意味reviewへ無理に渡さず、別件数として集計する。原review artifactのhash照合・保存とreviewerの独立性は呼出元責任。人間gold pendingを成功へ変えない。

## 実装・検証の順序

1. pure request builderとschemaを追加。正解読込なし・入力のみで決定・余分な引数拒否・未知キー拒否・利用不可context参照除外・凍結source不変をテストする。hashはID風の評価メタデータではなくinput全体の照合に限定する。
2. pure response parserを追加。完了/拒否/途中切断/複数text/別hash/無効参照/契約違反を合成responseで確認する。refusalの具体的なResponses envelopeは実装前に公式資料で再確認する。
3. 独立コード・安全レビューと関連/全Workerテスト。既存runや停止lockを再利用・解除せず、runtimeにも接続しない。
4. 新しい有限runを設計する時に送信対象と件数、body hash、予約、送信側上限、timeout、費用見積、停止/再開条件、review保持を固定する。ここでは実API送信を許可したことにしない。

初期設計時点では文書のみ。API/キー読取/有料run/本番変更0。ロールバックは新設計の採用を止めるだけで既存挙動に影響しない。Projectの資料の更新: なし。

## 独立確認と残件

独立Plannerが既存小契約との整合を確認し、文書上の未解決High/Mediumなし。fault2件の除外は将来のローカル評価callerがharnessから行い、builderへ渡さない。input本文からfaultを推測して送信対象を変えない。既存validatorはnon-okを許すため、新parserではwireのok固定を別途検証する必要がある。

fixture/validatorの記録済みsource hash一致と30case/モデル対象28/ローカルfault2/要求29を確認。文書変更のみでWorker全テストは再実行していない。前工程1693成功は今回の実装やモデル性能の証明ではない。builder/schemaとparser実装、実API受理、実モデル意味評価、人間gold確認はこの初期設計時点では未完了。

## 公式資料の確認

OpenAI Docsを利用し2026-10-16に検索・本文取得した。[Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=responses)のstrict schemaとrefusal/不完全出力の扱いを参照。上記は互換性を狭くした設計案で実API受理は未確認。[GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna)のモデル指定とreasoning対応を確認した。価格やアカウントでの利用可否は本設計の検証結果に含めない。


## 後続のZod実装

[Docling/Zod導入記録](RAG_DOCLING_ZOD_ADOPTION.md)で別candidate moduleにZod wire schema・input専用builder・Responses parserを実装。provider object/model/error/incomplete/usage/出力数/reasoning状態を確認し、本文はZodと既存validatorの両方を通す。正規化usageとrequest/response hashを返すがdispatchVerified=false。外部意味review/技術失敗母数の集計は将来caller責任で、有限transport/実API受理・実意味評価・人間goldは未完了。既存凍結fixture/validator/reviewは変更しない。
