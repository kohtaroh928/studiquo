# Docling private HTTP transportの受け入れ契約

2026-10-17。原PDF自動解析の第2単位。既存の有限runnerの手前に、ローカル内でのみ起動できる通信アダプターを追加する。外部公開・Cloudflare binding・Docker・アプリ送信経路はこの単位に含めない。runtimeやモデルの追加取得なし。

## 通信仕様

- 明示的startで127.0.0.1だけへbindし、import時に起動しない。trusted port以外のbind先や任意URLをrequestで受け付けない。
- HTTP/1.1 POST /parse、Hostは当該loopback port、Content-Type application/pdf、単一の厳密Content-Lengthを必須とする。符号や空白混入、重複header、TE/CE/Expect、obs-fold、不正CRLF、query/pipelineを拒否する。
- headerは終端含め8KiB、原PDF10MiB、header+body総受信期限10秒。接続4件・解析1件、本文を読む前にbusyを拒否する。待ちqueue/自動retryなし。
- 固定runnerへbytesとcancel eventだけを渡す。通常の完了は4MiB以下のprepared JSON。応答はno-store/Connection close、送信待ち上限5秒、固定errorだけで本文/filename/path/内部exceptionを返さない。

## 取消・終了

body後のEOF（TCP half-closeも含む）、追加bytes、解析待ち期限、server shutdownはcancel eventを立てる。async Taskの取消だけでthreadが停止したと扱わず、shieldでrunner実終了を待つ。実終了までjob slotを保持する。cleanup_failedはserviceを利用不可にし後続jobを拒否する。

解析待ち期限125秒はcancelを要求する時点であり、native code/host全体のhard上限保証ではない。既存runnerの120秒処理・子process group停止・cleanupを利用する。trusted runnerが戻らない場合のVM強制停止は将来のcontainer境界で必要。socket handler/taskを放置したまま停止成功としない。

## 検証と安全境界

loopbackの実socketで成功、不正header/容量、slowheader/body、欠損body、pipeline/halfclose、接続上限、busy、解析中切断、timeout、server shutdown、cleanup失敗後拒否、error非漏洩を確認する。synthetic子を使った本物runnerとの統合で子停止/一時job削除も確認する。実利用者PDFや有料APIは使用しない。

loopbackは本人認証・OS sandboxではない。同一host内の別processは接続可能なので、外部公開や本番個人情報の受付には使わない。Container ingressからの到達性も確認していない。Cloudflare接続時は原PDF別同意、本人/文書世代認可、admission、通信/メモリ/ファイル数隔離と孤立job回収が前提。このunit自体のrollbackはlistenerを起動せず未接続moduleを使わないこと。

設計は既存Plannerで独立確認済み。最終Code/Security reviewと実socket試験後に結果を別報告へ記録する。Python公式参照: [streams](https://docs.python.org/3.12/library/asyncio-stream.html)、[tasks/cancellation](https://docs.python.org/3.12/library/asyncio-task.html)。
