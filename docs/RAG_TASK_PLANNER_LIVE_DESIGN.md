# TaskPlan v2の有限API評価

2026-10-15。High（評価の外部送信・利用量/secret管理）。本番v1/凍結bank/未使用20問/旧評価moduleは変更しない。固定6問のrequestとJSON parserの接続だけを対象とし、抽出内容の正しさは別のoracle/独立意味評価で扱う。

## 計画と受入

1. 新moduleでprivate先行予約journalと非stream transportを実装。新規directoryの排他的作成をrun lockとして用い、既存directoryを開き直さない。既存E50は凍結hashを保つため変更しない。既存同等のowner/mode/symlink/hardlink検証、O_NOFOLLOW/O_EXCL、fsync、hash chainを用いる。
2. run directoryは新規のみ。既存なら成功/失敗/未確定を問わず送信しない。CLIは後続工程で固定run pathを用い、未確定の送信を別pathで再送しない。ライブラリの別directory全体を統制するglobal budgetではなく、今回の固定run運用で重複を防ぐ。
3. 固定6bodyのみ、最大6送信、1送信予約8192microUSD、合計49152microUSD。input32768×0.125+output8192×0.5というcache-write側の保守的試算。予約は失敗時も返さない。料金/外部上限は実行前に再確認、請求額の保証ではない。
4. 各60秒、全360秒、request24KiB/response256KiB。API endpoint固定/redirect:error、初失敗停止。timerはfetchだけでなくresponse読取完了まで。未完了のfetchが後から解決しても後続送信を行わない。
5. manifest→reserved fsync→送信→parser→private completed fsync。失敗は固定codeのみでfailed、本文や上流error/secretを保存しない。成功planには合成質問の引用が含まれるためprivate journalだけに保存し、stdout/RESULTS/Notionへ出さない。生responseは保存せずhashだけ。
6. mockで6送信/先行予約/権限/再実行拒否/HTTP失敗/不完全/invalidplan/timeout/oversize/secret漏れを確認後、独立安全レビュー。既存テストも実行する。実APIはその後の限定評価で、今回まず検証基盤を完成する。

## 障害と撤回

予約fsync失敗なら送信前停止。送信後の保存失敗は未確定扱いでrunを再実行しない。HTTP拒否/timeout/JSON不正/引用不整合も初失敗で停止し、勝手にprompt/モデル/keyを切替えない。既存run pathを削除してやり直さず記録を監査する。APIキーは呼出時に渡し、今回はロード/変更しない。テストでは合成のダミー文字列だけ。実行しなければ外部影響なし、採用済みアプリ/API/DB/flagsのrollback不要。

## 残る確認

実Lunaのschema受理・reasoning/cache形式互換・UTF16offset・原子的要求網羅性・oracle人間確認は未評価。通信の成功をRAG回答精度と呼ばない。実検索/PDF/OCR/iPad・本番有効化は別gate。独立レビューの指摘と最終テストを完了後に追記する。

参照: [Lunaの公式モデル仕様と料金](https://developers.openai.com/api/docs/models/gpt-6-luna)（2026-10-15）。Projectの資料の更新: なし。


## 実装時の確認

独立Plannerの事前確認を反映。各送信のtimeoutを全体残り時間以下にし、header後の本文停止もcancel/abort。全6bodyとrequest/response/schema/runner source hashをmanifestへ固定。raw全体でsecret反射を拒否し、生responseは保存しない。予約保存失敗は送信0、completed保存失敗も同run再送不可。既存run/symlink/stale artifactを拒否。専用8/関連34のmockテスト成功、全Workerと最終レビューは確認後に追記する。

CLI・キーloaderは未追加、実API呼出0。ライブラリはテスト用fetchと短縮timeoutを注入できるが、上限の引上げ・任意body/modelの注入はできない。別directoryへの反復を技術的に防ぐglobal ledgerは未実装。実行工程で固定pathを使用し、今回の未確定runを削除/別pathへ再作成しない。


独立コードレビューでMedium2件（予約fsync中の期限超過後送信、進捗通知失敗によるterminal二重化）を修正。予約後に残り時間を再確認し、進捗通知を送信/保存の例外処理から分離。completed書込失敗では二つ目のterminalを追記せず停止し、保存されたcompleted bytesもfsync未確定の可能性があるため呼出失敗時は成功と扱わず監査する。close失敗は固定エラーに正規化。回帰2件追加、対象10/関連36成功。最終全体テスト/安全レビューを再確認する。


## 最終mock検証と限定実行

修正後の対象10/関連36/Worker全1,350成功（失敗/skip0）。独立コード10/安全10成功、未解決High/Mediumなし。source/request hashはRESULTSへ更新。公式モデルページで料金を再確認済み。レビュー後に固定path `/private/tmp/studiquo-rag-task-planner-v2-20261015-01` の新規実行だけを開始した（最大6、予約0.049152USD、初失敗停止）。このpathの実行完了を監査してから抽出内容を評価する。キーは既存loaderでメモリに読み、表示/保存/変更しない。結果は完了後追記する。

## 実Luna 6問の結果

固定runは6送信/6完了、失敗/未確定0。journal13行（manifest1+予約6+完了6）のchainとprivate0600を監査。schema受理、完了/usage、質問のUTF16引用整合を実APIで確認できた。モデルのscope数は順に2/2/2/3/3/3、計15。人手oracleは16scope。厳密な操作/属性/対象/状況/依頼spanの完全一致は全16項目で0だが、これは**注釈位置も含む一致数であり、回答要求の理解精度0%という意味ではない**。妥当な別span、結合、漏れを独立意味レビューで分ける。入力/結果を修正して成功に見せず、この初回結果を保持し追加送信は止めた。

usage input4728/output5357（reasoning3775はoutput内）/total10085。待ち時間平均8.713秒、min7.679/max10.243秒、直列合計52.281秒。uncached Standard試算0.0031513USD、cache-write側上限率での試算0.0032695USD、予約0.049152USD。実請求・キャッシュ適用は未確認。6問1回の結果でp95や汎用精度を断定しない。検索/回答生成を含むRAG全体の遅延ではなく要求抽出だけであり、本番へ常時追加する判断はしていない。

実呼出には既存キーを使用し、キー変更/表示・deploy・DB操作なし。原文planはprivate journalに留め、RESULTSにはhash/件数/usage/注釈IDのみ。独立意味レビュー完了後に内容を追記する。人間gold確認と公開判断はpending。

## 独立意味レビューと次の一手

独立AI reviewerが固定質問/契約/oracleと全15plan taskを照合。index0のr1/r2は別料金を1taskへ結合し、attributeが回答対象ではなく疑問語になった。対象名は残っているが独立scope保持は未達。index3のr1は通常条件をattributeへ内包しconditions=[]で、語の完全脱落ではないが条件role分離が未達。

index1/2/5は要求/対象/状況を意味上保持。index4は説明対象分割と初心者条件を保持し、概念subjectの追加やspan境界差は妥当な別注釈。index0r3、index3r2/r3も保持。全15taskでunknown固定の偽装や実行命令なし。厳密注釈一致0と意味保持を混同しない。独立AIの評価であり人間gold確認はpending、少数で汎用精度を数値化しない。要求結合/条件roleの未達があるため本番採用は保留。

次は今回の入力/結果/hashを凍結したまま、独立値要求と比較要求の分け方、属性と疑問語、条件roleを一般規約で補足する候補を検討する。別の開発用合成問題を先に用意し、過分割を起こさない比較/要約と対にして独立oracleへ照合する。既存6問だけの成功へ合わせる変更や未使用20問による調整を避ける。即時の追加APIはしない。runtime v1/最終回答生成処理は維持。
