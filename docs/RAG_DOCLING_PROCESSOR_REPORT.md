# 有限Docling processorのローカル実装

2026-10-17。前回使用量制限で中断したunitを完成した。原PDF自動解析の第1単位であり、HTTP/Cloudflare/アプリ自動送信はまだ接続していない。

## 変更

services/docling-processor/にbytesだけを受けるPDFProcessor、固定child_entry、返却manifest検証とsyntheticテストを追加した。子は既存offline Docling→本文分割→metadata→prepared exporterを呼び、資料全体の成功packageだけを返す。原PDF10MiB/20page、返却4MiB、private directory0700/files0600、固定parser/version/profileを使用する。任意URL/command/filenameは入力できず、runtime/modelを取得しない。

処理期限120秒、cancel時は子process groupへSIGKILLを送り、通常終了でも残った同group子孫を停止する。期限チェックとcleanupのreap待ち最大2秒は厳密なAPI総時間保証ではない。stdout/stderrはDEVNULL、環境はallowlistで、原文・パス・内部parserエラーを返さない。kill/wait/削除を独立して試し、失敗は固定cleanup_failed。削除未完のままsuccessを返さない。

返却JSONは容量/深さ/構文token/重複key/非finite値、固定no-vector方針、文書・record digest、namespace、連続全pageとnested shapeを検証する。Worker token estimatorまで親で複製しない。既存child exporterと受信後Swift/Worker最終検証を省略できる契約ではない。

## 確認した結果

- 新unit19テスト成功、失敗0。親も同19件を実行。独立安全reviewも19件成功。
- 既存tools/doclingの49件を親で再実行、成功。mcp-server/iOSコードは今回変更していないため全Worker/iOSテストは再実行していない。前工程の結果を今回再実行と扱わない。
- Implementer実Docling合成2page: 8475bytes、約7.5秒。
- 親の別private jobで実Docling合成2page: 8475bytes、5.73秒、semanticApplied=false、返却時job directoryが空であることを確認。
- 両smokeとも既存のlocal専用runtime・checked modelを使用し、有料API/鍵アクセス/モデル追加取得なし。資料本文を出力・repository保存していない。所要時間はこの2page・既存modelでの観測値で、20page/オンラインcold startの性能保証ではない。
- git diff --check成功。既存未コミット変更を保持、commit/push/deploy/remote migrationなし。

## レビューで直した問題

cleanupでkill/waitが失敗すると削除へ到達せずraw errorが漏れるMediumを修正。fault test初版は実killpgのProcessLookupErrorが先に起き、意図したPermissionError注入が成立していなかった。直接fault注入へ直して既存の成功禁止・削除assertionを維持した。実smokeでextract_pdfがstrパスを要求する不整合を発見し、固定entryからstrへ変換する回帰テストも追加した。最終独立reviewのHigh/Medium残件なし。

## 保証外と次の工程

このunitは非公開ローカル処理のみ。Pythonネットワークguard/process group/RLIMITはOS sandboxではない。ネイティブコードのgroup離脱、job総メモリ・総ファイル数・通信、親host強制停止時の物理消去は保証しない。公開前にはcontainer隔離、private transport、admission、orphan cleanup、原PDF専用同意、本人/文書世代の認可と取消・削除連携が必要。

次はprivate transportの有限受信/切断取消/同時実行/固定errorを実装し、その後Workerの同意とadmission、iPad接続へ進む。配備と追加購入は別承認工程。原PDF自動解析の稼働完了・実資料の精度向上とは主張しない。RAG feature flagsと自動スケジュールPAUSEDを維持。

Project資料の更新: 今回は独立未接続unitとRAG専用報告のみのため追加対象なし。前工程のARCHITECTURE/DATA_AND_MIGRATIONS/SECURITY_AND_PRIVACY/HYBRID_RAGの複製更新は依然必要で、Desktopは変更していない。
