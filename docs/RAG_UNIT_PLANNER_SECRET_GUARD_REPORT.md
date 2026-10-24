# v4通信準備：復号後の秘密反射チェック

2026-10-15。使用枠95%を確認し、通信全体を途中まで変更せず、完結可能なpure helperだけを追加した。並行作業なし。旧offline manifest/journal/sourceを変更しない。API・キー読取・本番変更0。

`unit-task-planner-secret-guard.mjs`はJSON文字列と呼出元から渡されたkeyだけを受ける。raw文字列での一致に加えて、JSONを1段復号した全string値/property名に同じkeyが含まれないことを反復走査で確認する。戻り値はundefined、拒否は固定codeのみで本文やkeyをechoしない。入力最大256KiB・深さ64・node65536・key形ASCII16〜512文字を固定し、超過は補正せず拒否する。IO/log/key loader/通信は持たない。

対象7件は通常JSON、raw反射、Unicode escape/混在表現、復号後property名、入力型/UTF8 byte/深さ/node上限、多重JSONの接続条件を確認する。使用するkeyは固定の合成test値のみで実資格情報ではない。全Workerは追加6件まで含む1,503件成功、失敗/skip 0。最後に追加した多重JSON1件は対象7件で確認し、全Workerは再実行していない。独立最終レビューも7件成功。[結果JSON](RAG_UNIT_PLANNER_SECRET_GUARD_RESULTS.json)にhashと結果を記録した。

独立コード・安全レビューでHigh/Medium指摘なし。**helperはJSONを1段だけ復号する。** Responsesのoutput_text.textにはさらにplan JSONが入るため、raw responseへの適用だけでは十分でない。transportへ接続するときは、(1) request JSON、(2) raw response、(3) 最終parser結果をJSON化した保存対象（plan/provenance等を含む）へ適用し、最後の検査が成功するまでjournal.completeを呼ばない。7番目の回帰ではrawのみで見逃す例と最終保存対象での拒否を確認する。

一般的な秘密検出/DLPや任意encodingの自動復号を提供するものではなく、指定したkeyの文字列反射を拒否する限定機能である。transport/journalへ未接続のため保存経路全体の安全性は未確認。実API/schema受理/モデル意味品質も未評価。

次はこのhelperを含めて新bounded transport/manifestを実装し、deadline/bodycancel/固定診断・上の3箇所検査をmockと独立レビューで確認する。既存4runは再送・解除しない。本番v1/未使用20問保持。使用制限に達したら切替やresetで回避せず次回へ回す。

Projectの資料の更新: なし。
