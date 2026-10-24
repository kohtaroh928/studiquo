# 不足情報補充の実モデル障害回復確認（2026-10-10）

作業先 `.worktrees/rag-wip` / `codex/rag-wip`。ユーザーの「次の作業に進んで」に基づき、前回未発動だったreserve補充を確認した。

**結果: 実Cloudflare・Gemini経路で、初期本文読み込みの欠落からの補充・回答は成功。自然質問での補充成功率を測った結果ではない。**

## 方法と結果

架空機器の合成Notebook10ページを使用。1〜8ページは型番ABC123の異なる取扱説明、9ページは100円・送料別途・法人向け、10ページは補足。実資料・個人の学習内容は送信しない。

実`@cf/baai/bge-m3`（1024次元）、Vectorize、D1 FTS、`@cf/baai/bge-reranker-base`で候補・順位を取得。順位・スコア・owner/scope SQLは改変しない。

| ケース | 初期不足 | 追加読み込み | 最終出典 | 回答 |
| --- | --- | --- | --- | --- |
| 自然質問: 価格と型番 | なし | 0 | 9,5,6,8,7 | 正しい値・条件 |
| 自然質問: 型番を先に質問 | なし | 0 | 9,6,5,7,8 | 正しい値・条件 |
| 初期の型番本文欠落を再現 | 型番 | 1 | 9,2 | 正しい値・条件 |

自然質問の候補順の観測は、同一質問の私有probeの別リクエスト。公開APIのGemini回答も出典source/page整合性と原文を照合した。私有probeだけを根拠に公開自然リクエストの追加読み込みの発動を主張しない。

障害回復試験は、私有loopback helperのみで、初期5回のowner/scope済みneighbor読み込みのうち型番行だけを空の結果にした。D1データの削除・書換え、Vectorize候補の変更、モデル出力の偽装は行わない。

- 実モデルが選んだ初期ページ: `[5,9,6,8,7]`。
- 型番の初期読み込み4件を欠落させ、実際に使える初期参照は価格の`[9]`のみ。
- 欠けた情報: `detail:0:model`。
- 追加の正常な読み込み: ページ2、1回。
- 最終参照: `[9,2]`、必要情報の欠落なし。
- 実チャットでも同じfirst5欠落と6回目のページ2取得を観測。`grounded`と出典DB一致を確認。
- Gemini回答はABC123・100円・送料別途・法人向けを保持。独立レビュアーが原回答と合成原文を照合。
- retrieve/実チャットそれぞれ通常のEmbedding1＋reranking1のみ。補充のための追加モデル呼び出しはなし。

自然の2質問では価格が最初から上位にあり補充は不要だった。この障害注入の成功を、実際の自然検索ミスの回復率・一般精度・本番品質の保証として扱わない。型番の各ページは固有の説明を持つため、完全一致重複の削除対象ではなく、自然質問は依然5出典を返す。

## 登録・反映待ち

初回は10ページ登録成功後、5秒間隔24回以内にreadyにならず停止。待機理由を記録していなかったため、この試行の原因は未確定。成否にかかわらず無効化・削除を完了した。

2回目は同じ合成資料・順位ロジックのまま、待機理由を記録し最大5分へ延長。D1の10件に対し途中のVectorize ID取得とindex countが0で、`vector_pending`を確認。5秒間隔28回目でready。最終diagnoseで10/10の1024次元・有限値・owner/source/page metadata一致を確認。

登録受付と検索可能になる時点には差がある。Notebookのコード不具合と断定せず、反映待ちの状態・時間制限を利用者へ伝える必要がある。今回は新たなreadinessコード変更を行っていない。

## 検証・安全・最終状態

- 最終runの17/17チェック成功（自然2問＋障害回復1問、別owner/空folder、idempotency、source削除、停止・削除を含む）。
- 公開WorkerのJSは前回864/864テスト済みsnapshotと全ファイル一致。dry-run成功。独立安全/品質レビュー済み。今回Worker製品コード・iOS・migration・binding変更なし。
- 私有retrieval copyは候補/選択/不足前後の観測3行のみ追加。本文・Embedding値を運用ログに出さない。元のhandleAI→retrieve経路にも同じ限定読込障害を適用し、実チャットのread列を確認した。
- 公開チャット2問＋私有実チャット1問まで。HTTPは90回、helper Workers AIは60回の枠。pollingはモデルを呼ばない。helper枠は公開APIのモデル呼出を数えないため総モデル上限ではない。
- 復旧は先に公開RAG/AI無効化・一時secret除去、その後データ削除/Vectorize反映確認とした。
- **終了active版 `6c18c267-1fb9-4612-b9d8-55796819c66e`**。RAG_ENABLED=false / AI_PROVIDER_APPROVED=false、公開status HTTP200 enabled=falseを独立確認。一時GEMINI_API_KEYなし、既存secretを維持。
- 今回2試行の固定合成owner計4名のD1 sources/pages/chunks0、FTS全体0、専用Vectorize全体0を独立確認。削除バリア4件は保持。
- 生成session/KV検証metadata/確認session削除、私有helper2個停止、一時credentialファイルとhelper state削除済み。
- 本番は変更していない。親の`.dev.vars`にあるユーザーのAPIキーは削除していない。

## 費用・プライバシー・残る作業

登録は2試行で合成10chunkずつ計20chunk。成功runの同一データ再登録では追加Embedding0。質問Embedding/rerankingとGemini3回、D1/Vectorize/Workers操作が別途発生。実請求額・Gemini token数は未測定。外部送信先・保存種類・プライバシーポリシーの変更なし。

残る作業:
- 人間が確認した未見の質問・資料で、自然な検索ミスと補充の品質を評価する。
- 同一テーマの冗長な出典と、既存の対象/条件parser制約を改善・検証する。
- Vectorize反映待ちのUX/監視/期限を代表的規模で確認する。
- 実紙OCR、実iPadでの出典タップ、本番費用監視と有効化前の準備。

[集計と観測](RAG_RESERVE_RECOVERY_STAGING_RESULTS.json) / [前回の実モデル確認](RAG_EVIDENCE_SELECTION_STAGING_REPORT.md)。

Projectの資料の更新が必要: [設計] HYBRID_RAG.md、[リリース] 00_残タスク表.md、今回のrelease記録。Desktop複製は変更していない。
