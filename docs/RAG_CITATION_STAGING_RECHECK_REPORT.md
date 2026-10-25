# 出典修正後の100ページstaging再検証（2026-10-09）

作業先 `.worktrees/rag-wip`、`codex/rag-wip`。ユーザーが承認した配信・合成100ページ再検証・削除無効化を実施した。本番は変更していない。配信前にサーバーテスト827件成功、113 JSファイルのスナップショット一致を確認し、独立安全レビューを実施した。レビューで品質判定の不足を指摘され、比較の両期待ページ、単純質問の出典集合、反映後3回連続成功を明示判定に追加した。

## 結果

実環境の **76/76確認成功**。100ページ／100chunkを5ページずつ20回で登録し、登録時間は **120.461秒**。最後の登録からreadinessでreadyを観測するまで **87.293秒**。10秒間隔の確認と質問試験を挟んだ観測時間であり、正確な反映瞬間ではない。同一sourceHashの再登録では全100ページskip、追加Embedding0件。

光合成の質問は、最初の試験（登録後5.710秒）から反映後の3回まで **7/7回grounded、出典1ページだけ**となった。前回混ざった植物の根の86／87ページは返らなかった。これは同じ合成質問の小規模な繰り返しであり、一般的な検索成功率や全ページのANN可視性を保証しない。

| ケース | 状態 | 出典ページ | 回答完了まで |
| --- | --- | --- | --- |
| library | grounded | 1 | 5.938秒 |
| folder-ocr | grounded | 5 | 3.700秒 |
| notebook-ocr | grounded | 7, 10 | 6.151秒 |
| current-page | grounded | 11 | 3.861秒 |
| comparison | grounded | 3, 6, 5, 1, 31 | 2.874秒 |
| compound | grounded | 3, 5, 2, 1, 4 | 2.709秒 |
| wrong-folder | fallback | なし | 2.535秒 |
| other-owner | grounded | 1 | 4.658秒 |

公開チャット8問が完了した。単純質問では余分な出典を除外し、比較では期待した1／5ページの両方、複合では必要な1ページを取得した。比較回答の糖分解と光合成、複合回答の材料／生成物は合成資料と一致した。folder／notebook／current pageの所有者とscope、空folderの通常回答、別所有者の分離、source削除、account削除のRAG実装関数も確認した。

**残る品質問題:** 比較の出典は3／6／5／1／31ページで、蒸発（6）と光の屈折（31）が混ざった。必要な両主題のページが残る条件は満たしたが、比較出典の適合性がすべて合格したとは扱わない。複合質問も最大5ページを残す設計であり、必要最小限の出典を保証しない。

## 安全確認と最終状態

最終配信 `3cb1bc6e-29cd-4906-9f00-d049e5a9bf85`（100%）、2026-10-09 21:53:26 JST。RAG_ENABLED=false、AI_PROVIDER_APPROVED=falseへ戻し、一時GEMINI_API_KEY削除をsecret名一覧で確認した。生成セッション・検証用KVも削除済み。今回の両固定合成所有者のD1 source／page／chunk0、FTS全体0、専用Vectorize全体0を読み取りで確認した。再保存防止のhash削除バリア2件は保持する。

実Sessionからcanonical userを求め、bodyの偽account情報を信用しない既存経路を使った。Vectorizeは所有者filterを付け、D1でも所有者とscopeを再確認する。本文・AI prompt・Embedding値の運用ログは追加していない。実紙資料やユーザーの学習内容は外部送信していない。合成回答は私有一時ファイルにのみ保存し、結果JSONへは集計値を掲載する。

stagingの一時チャット上限は利用者10／全体20とした。前回と同日の6チャットに今回8チャットを追加するため、従来の全体10では検証できない。終了時に元の設定へ戻した。私有モデル呼出のKVカウンタは厳密な原子的制限ではなく、実行側の固定回数・HTTP120件上限で検証範囲を制限した。

## 変更と運用

今回アプリ／Workerコードの追加修正はなし。前工程のreference-selection／search-branches／retrieval／readiness修正版を凍結して配信した。migration、Vectorize index、metadata index、bindingの追加・変更なし。恒久secret追加なし。デプロイ前の配信版は9f03da7e-8c3b-4d81-9e7e-bce0e0853e87。コードをその版へ戻さず、新版のflag無効化をロールバック手段として実施した。削除処理とschemaを維持する。

費用の全請求額は未確認。100ページのEmbedding入力・推定費用は前回と同じ条件で、46,641文字／chunker推定25,737 token、BGE-M3単価計算約$0.000308844（無料枠除外、モデルtoken実測ではない）。別所有者1chunk、質問Embedding／reranker、8チャット、D1／Workers／Vectorizeは別。Gemini usageMetadataを公開APIは返さず、総額を断定しない。プライバシーの送信先・保存種類は今回増やしていない。

## 次に残る作業

- 比較・複合質問の余分な出典を減らし、複数の必要根拠を保つ独立評価を追加する。
- 実iPadを接続し、登録中／反映待ち／検索可能・確認停止・出典タップを確認する。今回はiOSコードを変更しておらず、実機・全iOSテストを実行していない。
- 合成PDFは以前抽出したtext layer80ページ＋合成scan20ページのテキストを再利用。実紙OCRや厚い100ページ資料、1,000chunk規模は未検証。
- 本番の契約・プライバシー申告・利用量／費用監視・移行／binding／secretの準備を確認してから有効化する。

[集計結果](RAG_CITATION_STAGING_RECHECK_RESULTS.json)／[実装と制約](RAG_CITATION_STABILITY_FIX_REPORT.md)／[前回の100ページ結果](RAG_100_PAGE_STAGING_REPORT.md)。今回の繰り返しでは一時fallbackを再現しなかったが、前回の原因が確定した扱いにはしない。

Project資料の更新: [設計] HYBRID_RAG.md、[リリース] 00_残タスク表.md、今回のrelease記録。Desktopの複製とProjectへのアップロードは変更していない。
