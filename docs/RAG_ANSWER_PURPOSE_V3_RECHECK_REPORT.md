# 回答目的v3の実API再確認と未確認回答の優先実行

日付: 2026-10-12。作業先: .worktrees/rag-wip / codex/rag-wip。未公開。

## 今回の結果

6callを計画し、実送信2回。回路source_onlyはHTTP200/STOPで完成、回路explainはGemini HTTP503（約8.3秒）となり停止した。後続4call・内部retry/fallback・追加runは未実施。この回で完成した比較対は0。修正後の背景表示、予約explainの品質は評価不能であり、v3が改善したとは主張しない。

要求モデルは既存defaultのgemini-3.5-flash、成功時の返却modelVersionはgemini-3.6-flash。generationConfigはproduction defaultのまま。ローカルproduction handleAIと同一snapshotの合成検索・real Geminiで、実Cloudflare検索/実PDF/OCR/iPadではない。

Codexと独立AI Code Reviewerが生成済みsource_onlyを確認。式・単位・成立条件・ダイオードの例外、未知の抵抗値、背景説明の抑制は保持。一方、計算不能の後に不要な代入式を追加し、Rを抵抗という量とΩ単位で表した数値のどちらで使うか曖昧な表記が残った。Lowの表記・簡潔さの残件であり数値誤答と判定しない。教師レビュー・汎用精度・繰り返し安定性は未確認。W01/W03の残件を保持し、今回promptをさらに変更して結果を混ぜない。

## 待ち時間と使用量

完成1callの所要約8.4秒。観測tokenは入力1,757、回答192、思考1,113、合計3,062。503のusageと確定請求/freepaid tierは不明。503の詳細原因は未特定で、prompt/検索の誤り、キー間違いと断定しない。

原本は/private/tmp/studiquo-learning-live-20261012-02/synthetic-results.json（private0700/0600）。前回01を上書きしていない。repoのRESULTS.jsonとNotionには本文なしmetadataだけを記録する。

## 評価順の変更

前回と同じsource_first固定だと、障害のたびに既に確認済みの回答を先に試し、未生成の予約explainへ到達できない。評価runnerだけに次を追加した。

- caseIds: 既存の合成3問題から非空・重複なしsubsetを指定。指定順を保持し、未知/空/重複/型違いを拒否。任意資料や別問題の入力経路は作らない。
- styleOrder: source_first/explain_firstの固定enum。defaultは従来のまま。
- CLI: STUDIQUO_RAG_LEARNING_CASES、STUDIQUO_RAG_LEARNING_STYLE_ORDER。キー読込・出力作成・index・送信前に検証する。
- planned=requestedは選択問題数×2、caseIds/styleOrderを保存する。逆順でも同一資料・質問・generationConfig・chunk出典の比較を維持する。

次回は予約explain→source、回路explain→sourceの2組4callを計画できる。今回この順序での実API送信はしていない。順序効果を報告し、以前のsource_firstと合算した精度を出さない。

6call/60秒本文込/外部dispatch6分/512KiB、固定host/path/model/query・redirect拒否、最初のエラーで完全停止、秘密非保存、private新規出力の既存制約は維持する。外部期限はローカル後処理の厳密な全体deadlineではなく、強制終了時に途中結果を保存できない既知の評価用制約も維持する。

## 変更・検証

- 変更: mcp-server/scripts/rag-quality/learning-live.mjs、mcp-server/src/rag-learning-live.test.js。
- 新規: 本報告、RAG_ANSWER_PURPOSE_V3_RECHECK_RESULTS.json。
- 文書更新: HYBRID_RAG.md。
- productionの回答指示/Worker/iOS/DB/binding/secret/flagsは今回変更なし。migration/deploy/push/merge/commitなし。

Plannerが選択検証/比較の保持を独立確認、Security Reviewer/Code Reviewerが実装をレビュー。High/Medium残件なし。安全Reviewerはrunner10テストを独立実行し成功。最終対象28件成功（追加3件を含む）、全Worker1,134件成功（失敗/skip 0）。JS構文/git diff --check成功。追加テストは選択順とexplain_firstのsame snapshot、無効設定0dispatch、最初の503で1dispatch後停止を検証した。mock合格を実回答品質と扱わない。iOS変更なしで再テストなし。

## 残件と停止

v3回路の補足表示、予約explain、W01単位付き量/数値とW03不要な代入、他問題/未使用問題/複数回、実Cloudflare/実iPadが残る。APIエラー時の自動停止を維持し、サービス不安定時に同一turnで繰り返し送信しない。今後のAPI可用性/モデル設定の切り分けは別条件として記録する。

評価onlyなので製品ロールバック不要。評価順を未指定にすれば従来方式に戻る。両RAG flagsはfalse。プライバシー方針・保存/削除仕様に変更なし。

Project資料の更新が必要: HYBRID_RAG.md。複製は未変更。
