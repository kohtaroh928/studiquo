# Step5-D2b-A: 停止観測の永続化と有限削除の前提確認

2026-10-20、codex/rag-wip。D2a以前の未コミット成果を保持。High/full、独立Planner/Code/Securityレビュー。**D2b全体とDO物理削除は未完**。

## 今回実装したこと

private DoclingJob.cleanup()で、VM destroyが実際に解決した後、v2 stateへ最初のdestroyConfirmedAtを保存する。同じgate内でcleanup用alarmを削除し、保存/時計検証/alarm削除が失敗したら成功ackを返さず、既存poison・上限付きretryへ進む。外部destroyはgateの外で待つ。timeout後に元promiseが遅れて解決しても、停止観測を後書きしない。

時刻は初回固定し、後の取消・再起動・alarmで延長しない。保存済観測時刻より時計が戻る場合もackを拒否して保持する。legacy stateへ時刻やv2契約を補完せず、期限後の空DO取消でも新stateを作らない。PDF・digest・token・本文の追加保存はない。

このfieldは**過去にdestroy解決とその記録に成功した観測**である。過去の観測後に別のcleanupが失敗しても履歴として残り、statusはpoisonedとなり今回のackは失敗する。現在のVM停止・全local task終了・reader cancel完了・MCPのlocal証拠・有限削除許可を単独で証明しない。停止済みの結果をmarker縮約や削除に利用するコードは今回ない。

## 物理削除を入れなかった理由

全stateを消すと最終観測clockも消える。時計が大幅に戻ると、古いnotAfterが再び未来になり、空DOだけでは新規と再送を識別できない。notAfter+長いgraceやlocal lastObservedAtだけでは解決しない。新テストで、保持markerは巻戻し後もparseを拒否する一方、**Map fixtureだけ**を人工消去した再起動では同じ契約の解析が通る反例を再現した。実storageを削除した試験ではない。

物理purgeの前提は、外部の単調fence/namespace incarnation、またはtrusted clockの保証と異常時に全入口を閉じる運用契約である。今回それを勝手に追加・承認済み扱いしない。長期保持を含む費用/プライバシー判断と合わせ、次の独立設計で選択する。

また、graceは125秒実行・10秒cleanup・10/30/90秒retryの合計だけで決めない。未解決cleanupの最大期間、遅延RPC・restart・時計差・receipt/adoption参照期間が未確定である。任意の短い定数を置かない。

retention用alarmは未追加。現在のalarmはcleanup専用であり、cleanup成功時は削除する。将来導入するときは、永続scheduleでcleanup/retryとretentionを区別し、1個のalarmに次の期限を選ばせる必要がある。completedのalarmがno-opの現状を、有限保持対応済みとしない。deleteAll/個別state削除/spent圧縮/purgeAt/新flag/config/remote操作はない。

## 検証

- private JS全51件成功（既存41、新10）、fail/skip0。新規は実destroy待機、初回値固定、保存障害、destroy失敗、alarm削除失敗、異常clock、再起動/alarm、legacy/expired empty、timeout後遅延解決、全消去clock反例。
- MCP側のv2通し12件成功。MCP production sourceは今回変更なし。前回の全1948件は今回再実行した成績ではない。
- 実local workerd/D1 18migration/service-binding RPC/SQLite DOで、MCP→private→DO→manifest→両証拠→精算、停止観測時刻の保存、intake削減/flag OFF取消と旧parse/replay拒否を確認。VM IOは合成adapter、実Cloudflare destroyではない。一時storage破棄済み。
- 既存の専用Colima VM・既存固定image `sha256:32018601399c0791a787fd72516acfd8fddce9fe568da12d6344a4c19792bc4d` でlinux/amd64 Doclingを再検証。合成2page、20.945秒、8454bytes、POST1回。実子process取消、試験processだけ0.3秒へ短縮した期限でkill/reap、job directory削除、不正PDF拒否、SIGTERM正常終了を確認。
- Linux隔離はnetwork none、host mounts/published portsなし、UID10001、code/model read-only、egress拒否。cgroup memory.peakは2,147,483,648bytesで設定した2GiB上限に到達した。追加資源校正が必要で、全資料の性能/余裕やOOMが無かったことまで保証しない。
- 今回のLinux試験は既存runnerを検証し、新JSのCloudflare Container APIと実Linuxをv2で一体接続した試験ではない。Cloudflareの実destroy/alarm/課金終了や実VM再起動後の挙動は未確認。
- 専用VMは最初に停止状態だったため、試験終了後にコンテナ残存なしを確認して停止状態へ戻した。新VM/モデル取得/イメージ再build・pushは行っていない。今回起動processは終了。

初回新test fileのfixtureコピーでconst二重宣言となりmodule読み込み失敗、重複を除去した後、全51成功。最初の専用VM statusは環境変数不足/権限制約で読めず、既存LIMA_HOME指定と正規権限で確認・起動・終了した。自動承認拒否の回避やサービス制限の切替はしていない。

独立Code/Securityは追加実装と当初9件を読取り確認し所見なし。最後のclock反例テストも追加確認対象とした。独立テスト・実Linux再実行はreviewerでは未実施。詳細とsource hashは隣接RESULTS.json。

## 次とrollback

次はD2b-B設計：全消去後にも残る再実行防止策とclock異常検知、legacy入口を再開しない配備方針、grace、全task/VM停止、cleanup/retention alarmの役割を確定する。その後marker縮約・物理削除を別実装/レビューする。外部fenceの新storageを作る場合も費用/保持/障害/owner削除を検討する。

今はmarkerを保持し、新規受付OFFでも取消/cleanupを維持。停止観測の履歴を停止証明として流用しない。追加fieldを知らない旧版へ戻しても有限削除許可にはならず、D2aのv2停止コード/schemaを維持する。配備・migration・有料AI・実PDF・commit/push/mergeなし、automation PAUSED。

Project再同期対象: DATA_AND_MIGRATIONS/SECURITY_AND_PRIVACY/HYBRID_RAG。Desktop複製・claude.ai uploadなし。共通handoffを更新。Notionは着手時更新だけ成功し、終了結果の追記は使用量上限により自動承認レビューが完了できず未実行。安全性を理由とする拒否ではない。D2b-B着手時に通常利用可能を確認後、同じ正規ツールで既存カードへ追記成功。

参照した公式仕様: [DO alarmは1個](https://developers.cloudflare.com/durable-objects/api/alarms/)、[SQLite storage/deleteAll](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/)、[Container destroy/monitor](https://developers.cloudflare.com/containers/api/durable-object-container/)。
