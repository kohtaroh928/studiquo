# Unit planner v4：質問のみの入出力

2026-10-15。Standardのoffline評価補助。既存v2/v3と本番v1は変更しない。

## 受け入れ条件と実装計画

- 固定の別開発8問だけをindexで選ぶ。paired candidateの操作・原子的scope規則5項目・Luna/medium設定は保持し、version/参照表現/statusの引用記述だけを置換する。任意質問や設定overrideを受けない。
- user JSONはquestion/questionHash/unitsだけ。unitsはserver由来id/textを含み、offset・oracle・review・期待taskを含まない。質問は同一内容がunitsにも含まれるが追加証拠ではない。unit境界は意味的な要求境界ではない。
- 指示にはラベルが未検証の解釈、unitが構造参照であって出典や意味支持ではないことを明記する。旧v2/v3・数値位置・prefix/suffix必須指示の残存を拒否する。
- v4 schemaはquestionHash/既知IDへ拘束。全objectの追加field禁止/全property必須。API用schemaは従来同様minLength/maxLengthを除くが、local validatorは上限/重複/status/unknownを保持する。
- requestは32KiB、responseは256KiB、planは32KiB以内。固定本文の変更やsize超過を拒否する。旧runnerの24KiB制限は変更しない。将来の新runner接続にはmanifest/body検査/予約予算を改めて整合させる必要があり、そのまま接続可能とは扱わない。fresh cloneで後続requestへの変更漏れを防ぐ。
- manifestは行ごとのparent/request/question/schema/instructions hashを持つ。出力hashは期待requestとのlocal bindingであり実送信の証拠ではない。
- responseはcompleted envelope/選択model/usage/単一assistant output_text/refusal/不正JSONを検証し、v4 local validatorを通す。失敗理由は固定codeのみ、本文echo/repairなし。本文は戻り値として呼出元へ渡すが自動保存/logしない。
- 原文provenanceは共通table一度だけ。意味pending/evidence unknown/release falseを維持し、形式の正しさを意味精度にしない。
- request/responseの新2module、mock回帰、独立レビュー、全Workerの順に確認する。旧4run再開/送信/鍵読取/runner連携なし。戻す場合は新moduleを使用しないだけで、既存API/本番schemaへの影響なし。

## 公式仕様と未確認範囲

[OpenAI Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs?api-mode=responses)を2026-10-15に確認。strict JSON Schemaの追加field禁止・必須propertyを満たす形式を用いる。仕様上の制約とlocal mockのみでは、実Lunaが新schemaを受理することや意味品質を証明できない。実APIと費用は次の有限runの別安全gateで確認する。今回はAPI0。

## 検証結果

新2moduleとmock回帰を実装済み。対象9件/全Worker1,476件成功、失敗/skip 0。独立設計/コードレビューはHigh/Mediumなし、独立対象9件成功。Low指摘のcloneテストはschemaを4→3へ変更しmanifest cloneも確認、対象再実行成功。固定8問/13候補taskは合成応答の形式/参照確認であってモデル品質ではない。旧v3 source hash/journal hashと4runlockを確認し保持した。未使用20問と人間oracle確認pendingは保持する。Projectの資料の更新: なし。

次は別v4有限runの設計を作り、manifest/source hash・1+3+4の意味review gate・予算予約・初失敗停止・diagnostic privacy・既存run再送禁止を独立安全レビューする。今回のIOに通信処理はない。
