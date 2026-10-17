# Quoted planner有限run：実装時の回帰テスト表

2026-10-15。[High設計](RAG_QUOTED_PLANNER_LIVE_DESIGN.md)を実装可能な確認項目へ分解する。これはテスト計画であり、以下のテスト実装・実行が済んだという記録ではない。既存paired runnerのテストは参照用とし、v3対応の代用にはしない。

| ID | 注入する状況 | 必須の確認 |
| --- | --- | --- |
| QL01 | 正常な8件と段階監査 | 送信は1/3/4件、累計1/4/8。stage終了後の自動送信なし。予約は累計8192/32768/65536microUSD |
| QL02 | stage_finishedだけ存在、監査未記録 | 次段階の送信0。監査待ちを失敗送信や意味合格と表示しない |
| QL03 | continue/pending/stopの監査 | continueだけ次へ。pending/stopは送信0。監査入口自体はfetch/キーを持たない |
| QL04 | 別run/旧checkpoint/別manifest/sourceの監査 | chainが整っていても送信0。stage/完了件数/担当種別/decisionの余剰・不正fieldも拒否 |
| QL05 | 同じdirへ2つのrun/reviewが同時にアクセス | 排他的lockで片方のみ許可。重複予約/送信/監査追記なし |
| QL06 | reserved fsync失敗 | 送信0。予約状態を自動解放せず監査停止 |
| QL07 | 応答後のcompleted/stage_finished/review fsync失敗 | 二重terminalや再送なし。不明状態を正常checkpointと扱わない |
| QL08 | close/rmdir/directory同期失敗 | 成功扱いにしない。lock再作成はbest effortとし、状態不明dirを自動再利用しない |
| QL09 | 改ざん、tail欠損、pending reserved、failedを含む履歴 | 再開時の送信0。chainを再計算した整形式の偽履歴も内容検証で拒否 |
| QL10 | quotedPlanと保存resolved planだけが食い違う履歴 | 固定質問+quotedPlanから再解決して不一致を拒否。保存resolved planを再解決入力にしない |
| QL11 | quote resolver/schema/fixture/request/parser/validator/runnerの変更 | 同journalの再開は送信0。全関連source hashを比較 |
| QL12 | 偽checkpoint件数/段階飛ばし/完了後再実行 | 1/4/8以外や順序違反は拒否、全生成完了後の送信0。最終意味監査は別状態 |
| QL13 | quote不一致/曖昧/余剰field/旧v2/permission偽装 | 固定reasonのみ。位置の推測・補正・前回plan流用・自動再生成なし。初失敗で全後続停止 |
| QL14 | HTTP失敗、不完了、refusal、usage/model不正、不明item | 固定phase/status/reasonのみを保存。上流本文/message/causeを含めない |
| QL15 | headers/body停止、予約同期中/保存直前のdeadline超過 | request60秒・stage60/180/240秒の上限維持。遅いbodyもcancel。期限後に正常完了を保存しない |
| QL16 | 不正UTF8、Content-Type不正、body256KiB超、plan32KiB超 | 上限で停止/cancel、部分応答を解析・保存しない |
| QL17 | request混入/response反射/例外にdummy secret | 本文なし固定error。private journal/共有結果/進捗にもsecretを含めない |
| QL18 | symlink/hardlink/owner/mode/inode/既存空dir | 不正dir/fileを拒否、送信0。初回mkdirとjournal作成は排他的 |
| QL19 | index/model/body/予算/時間上限を広げる引数 | 未知引数/任意入力/上限拡張を送信前に拒否 |
| QL20 | 未知usage/失敗後に同runや別dirから再実行 | 既存runの自動再送なし。予約維持、実費unknown。別dirの再送は運用上も禁止 |
| QL21 | 必須scope欠落/結合/対象誤対応/条件role未達 | 独立監査はstop。単なる妥当な別spanは注釈差として扱い、意味不合格に混同しない |

## 実装単位と次の着手点

1. 新v3専用manifestとjournal/replay。固定job/全source hash/quoted再計算、checkpoint、review bindingを先に実装し、送信なしmockで確認する。
2. 通信を持たないreview記録入口。lock/fsyncと固定schemaを確認する。
3. bounded transportと段階実行を接続。初失敗停止・deadline・byte・secret guardを確認する。
4. 対象/全Worker、独立コード・安全レビュー。通過後だけ料金率を再確認し第1段階へ進む。古い失敗runは解除しない。

この表を全てコードテストだけで保証できるとはしない。特に別dirによる意図的な再送禁止、レビューの実際の独立性、OS障害下の永続lock保証は運用・監査上の限界を併記する。テストの実行結果とAPI上のモデル品質を分ける。今回は文書追加だけ、追加API/キー読取0。Projectの資料の更新: なし。
