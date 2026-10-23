# 対象role比較：stage0のprivate保存

2026-10-16。[比較設計](RAG_SUBJECT_ROLE_PAIRED_DESIGN.md)に従い、[pure台帳](RAG_SUBJECT_ROLE_LEDGER_REPORT.md)へ通信なしの保存wrapperを追加した。

## 範囲と受入条件

新`subject-role-paired-journal.mjs`は最初の1pair/2jobだけを扱う。別offline persistence manifestへwrapper自身のhashと既存ledger manifestの依存closureを保持し、外側headerと内側runIdを照合する。旧pure moduleを変更せず、旧manifest・旧runへ転用しない。transportAttached=false・persistenceAttached=true・reviewGateAttached=false・maxExecutableStage=0。review受付、packet生成、stage1以降、API、鍵読取は未接続。

canonical新directoryを0700、journalを0600・単一hardlinkとして作る。共通running.lock、O_EXCL、初期file→directory同期、予約recordのfsync完了後の戻りを必須にした。source変更やjournal/lock/directory差替えを各操作前に確認する。累積2MiB上限、同一fdの読込前後stat、UTF8 strict、canonical NDJSONとhashchain/固定planのreplayを使い、cached summaryだけを信用しない。

初期checkpointと最初のpair完了+stage_finishedだけ正常closeでlockを解放する。予約中・片側完了・checkpoint前・技術失敗・保存不明・poisonはlockを保持する。次のopenも、lockだけでなくreplayしたsafeReopenCheckpointを要求する。保存や同期が失敗した場合、成功を返したりterminalを重ねたりしない。closeのlock削除後にdirectory同期が失敗したら、元directoryを確認して停止markerの復元を試みる（OS障害時の完全保証ではない）。孤立artifactも上書き/再登録せず停止する。

## 検証と限界

対象14テスト：private mode・run/checkpoint保持、予約/partial/failed再開禁止、stage1拒否、同時open、symlink/hardlink/mode、byte/UTF8/切断/旧manifest/source/run binding/orphan、稼働中の同inode変更/差替/source変更、snapshot分離、余剰undefined/取り違え/不正diagnostic、short write/fsync、lock削除/directory同期失敗、close直後例外、読取途中のpath差替えを確認した。テストは合成mockだけ。全Worker1,582成功（失敗/skip 0）。独立コード14・安全12成功。安全レビュー後の追加2回帰はコードレビューでも独立確認し、実装moduleは変更していない。未解決High/Mediumなし。[結果JSON](RAG_SUBJECT_ROLE_JOURNAL_RESULTS.json)参照。

この保存処理はAPIを実行せず、通信のtimeout/secret guard/実送信とのbindingを保証しない。合成開発planのoffline検証に限定し、任意の実学習内容や秘密を安全保存できるものとは扱わない。raw response/prompt/keyを保存する入口もない。source hash・ローカルrunIdは本人認証・上流実行の証明ではない。同じOS userによる全記録の書換えを防ぐ監査基盤ではない。

rollbackは新wrapperを呼ばないこと。アプリ/Worker runtime/DB/migration/本番prompt v1・未使用20問へ影響しない。追加API/実キー読取0。次は中立packet/mappingと元review artifactを保存し、全先行reviewを再評価する入口を作る。その後に新manifestでbounded transportを接続する。今回のoffline runをpaidrunへ転用しない。

Projectの資料の更新: なし。
