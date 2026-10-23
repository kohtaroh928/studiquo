# Docling private HTTP transport実装結果

2026-10-17。原PDF自動解析の第2単位。既存finite runnerへローカル通信を接続した。CloudflareやiPadアプリへの自動接続ではない。

## 実装

services/docling-processor/private_http.pyへ、明示startで127.0.0.1だけにbindするHTTP adapterを追加。起動時副作用、任意bind先、URL入力、公開route、認証secretは持たない。固定HTTP/1.1 POST /parse、実portのHost、application/pdf、厳密な単一Content-Lengthを要求する。不正CRLF/obs-fold、重複header、TE/CE/Expect、query、pipelineを拒否する。

header終端含め8KiB、原PDF10MiB、header+body受信合計10秒、同時接続4・解析1。busyはbody受信前に拒否する。解析待ち125秒でcancel、応答4MiB、送信待ち5秒、no-store/Connection close、本文・path・内部exception非ログ、固定errorのみ。これらをhostやnative code全体の厳密なwalltime保証とは扱わない。

接続切断/EOF/half-close、追加bytes、解析期限、shutdownはcancel eventを立てる。threadのTask取消だけでは停止扱いにせず、反復取消を受けてもrunner実終了まで待ち、終了までjob slotを保持する。cleanup_failedは通常応答時だけでなく切断後の遅延失敗でもserviceを利用不可にし、後続解析を拒否する。shutdownはlistener停止→解析取消→handler/runner終了→listener wait_closedの順。

## 検証

- 新transport23件（実socket19・lifecycle mock4）＋既存processor19件＝42件成功、失敗0。親で全件実行、独立安全reviewでも全42件成功。
- 既存tools/docling49件を親で再実行、成功。
- 実合成2pageのPDFをloopback HTTP→実PDFProcessor→固定child→既存Docling→prepared exporter→HTTP応答→strict manifest検証まで通した。HTTP200、応答8477bytes、8.43秒、no-store、返却時job directory削除を確認。本文は保存/表示していない。1つの合成2pageの観測であり、20pageやcold start、実日本語資料の性能・精度保証ではない。
- git diff --check成功。今回mcp-server/iOS/既存runnerは変更なし、全Worker/iOSは再実行していない。過去の結果と今回実行を混同しない。

通常sandboxではloopback bindが許可されず、socketなし試験しかできなかった。親と独立reviewは許可されたローカル実行でsocket試験を実施した。外部接続・有料API・鍵読取・モデル取得・deployなし。

## 修正とレビュー

独立Planner設計とSecurity reviewを実施。次の不具合を修正した。

1. cleanup_failed後にも受付を再開していた。遅延失敗も含む停止状態を追加。
2. peer task回収中の再取消でrunner待機前に抜け得た。runnerのshield joinを優先し終了前のslot解放を防止。
3. 並行startやstart中closeでlistenerが残り得た。starting stateとpendingstart回収で防止。
4. success応答送信後に送信失敗するとerror応答を追記し得た。response_startedで二重送信を防止。
5. Python3.12 Server.wait_closedを取消通知より先に待つと、処理の自然終了を待ってしまった。通知と清掃を先にし、旧順序で失敗する回帰を追加した。

最初のsocket試験では19/22件中の不一致があった。shutdownは上記実装問題、拒否後TCP RSTはtestclientがContent-Lengthを使わずEOFを待っていた問題だった。testclientを宣言された応答長の厳密読取へ修正し、503・固定error・解析call増加なしのassertionを維持した。最終42件と独立確認は修正後の結果。未解決High/Mediumなし（非公開local unitの範囲）。

## 残る工程

このadapterは認証やOS sandboxではなく、同一hostの他processから接続可能。Container ingressに到達できる設計・運用確認はまだない。Cloudflare service binding、Linux/container model同梱、通信/メモリ/job資源隔離、orphan cleanup、admission、原PDF用の別同意・本人/文書世代認可、取消/アカウント削除連携、iPad送信は未実装。runtime/model/費用・配備は別承認工程。

停止はadapter.closeを待つこと。故障runnerが取消を無視して戻らない場合、threadの強制終了はできず、VM隔離・強制停止が必要。公開前にこの保証外を解消する。rollbackはこの未接続moduleを起動しないこと。RAG flags/自動スケジュールPAUSEDは維持し、既存コードや本番を変更していない。回答精度改善は未証明。

Projectの資料の更新: 今回の追加対象なし（未接続local unitとRAG専用資料のみ）。前工程の資料複製更新は別に残る。
