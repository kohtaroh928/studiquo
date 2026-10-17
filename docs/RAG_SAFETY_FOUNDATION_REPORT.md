# ホームPDF自動探索RAG：安全基盤の実装・検証

2026-10-11。作業先 `.worktrees/rag-wip` / `codex/rag-wip`。
ユーザーが指定した順番の1番目（旧②：サーバー安全基盤）をローカル実装・検証した。
デプロイ、remote migration、実資料送信、外部AI課金呼出、iPad自動同期は未実施。

## 実装したこと

- 新同意をサーバーの永続epochで管理。一度管理を開始したaccountは旧手動payloadへ戻らない。
- 安定document ID、資格（eligible/locked/excluded/trashed/deleted）、server generation、Worker発行source IDを管理。
- CASで古い更新を拒否。prepareのrequestIdとmetadata一致で再送を冪等化。hashは更新順序として扱わない。
- 同意撤回・ロック・除外・ゴミ箱・削除は検索を先に閉じ、物理削除をowner/source限定の永続jobで再試行。
- 登録SQLの全guard、Embedding直前、検索・neighbor・rerank直前、context最終組立、Gemini各送信/再試行直前で資格検査。
- 最終照合は出典anchorだけでなく本文に使った全neighbor IDを一つのD1 snapshotで確認。内部proofはAPIのcontext/citationsへ出さない。
- Vectorize accountKey事前filter、D1 account条件、旧AIProvider→WorkerAIProvider→Worker→Geminiを維持。
- 旧writerの補償はvector ID単位。source全体の削除と分け、後続writerを消さない。
- upsert前にID・writer lease・未確定状態を永続journal化。Worker強制終了でも削除対象IDを保持。
- 現行の毎時cronと認証済みcleanup APIで再試行。flag OFFでも失効・削除を継続。
- 普通のチャット、RAG disabled、未管理accountの手動登録、0006のみの既存資料読出/削除の互換性を確認。

## ファイル

新規：

- `mcp-server/migrations/0008_rag_control.sql`
- `mcp-server/src/rag/control.js`
- `mcp-server/src/rag/authorization.js`
- `mcp-server/src/rag-control.test.js`
- `mcp-server/src/rag-safety.test.js`
- `docs/RAG_SAFETY_FOUNDATION_REPORT.md`

今回編集（従来の未コミットRAG作業があるため、全dirty差分を今回の変更とは扱わない）：

- `mcp-server/src/rag/storage.js`：全登録guard・削除・補償journal・cleanup。
- `mcp-server/src/rag/index.js`：管理API、入力/rate/flag検査、status資格。
- `mcp-server/src/rag/retrieval.js`：全検索資格、rerank前・neighbor・最終proof。
- `mcp-server/src/rag/readiness.js`：資格付きsnapshot。
- `mcp-server/src/ai.js`：各Gemini dispatch直前の再検査。回答styleの再調整は今回行っていない。
- `mcp-server/src/worker.js`：既存scheduled handlerにcleanupを追加。
- `mcp-server/src/rag-quality-fixture.js`：新migrationを標準fixtureへ適用。
- `mcp-server/wrangler.jsonc`：production/staging共に `RAG_AUTO_INDEX_ENABLED=false`。
- `docs/HYBRID_RAG.md`、`DATA_AND_MIGRATIONS.md`、`SECURITY_AND_PRIVACY.md`、`RAG_AUTOMATIC_LIBRARY_DESIGN.md`：API・移行・安全性・開発順を記録。

## migration・設定・移行順

0008：`rag_controls`、`rag_documents`、`rag_cleanup_jobs`、`rag_cleanup_vectors`。
0006/0007は変更しない。remoteへは未適用。先に0008適用、資格guard付きWorker、iPad新同意/queueの順で公開準備する。
追加flagは初期OFF。新binding・secret・Vectorize index作成は不要。既存AI/Vectorize/D1/rate bindingを再利用。
管理APIは8 KiB、ID64文字、既存indexは512 KiB/最大10ページ。

API契約は[HYBRID_RAG](HYBRID_RAG.md)。新同意開始時に旧manual indexを失効させるため、将来のUIはその移行を明示する。新source IDと端末document IDの対応を端末で保持する必要がある。

rollbackは新機能をOFFにし、資格guardと0008を保持する。管理導入前の任意旧Workerや管理table削除に戻さない。未管理accountの手動互換と、managed accountの通常チャットfallbackを区別する。

## 実行した検証

| 検証 | 結果 |
| --- | --- |
| 新規control 12件 + safety 21件 | 33/33成功。Security Reviewerも独立実行 |
| 関連citation stability + safety | 48/48成功 |
| Worker全体 `npm test` | 1,118/1,118成功、失敗/skip 0、44.04秒 |
| Wranglerローカルdry-runビルド | 通常設定・staging設定とも成功。remote変更なし |
| `git diff --check` | 成功 |

初回の全体実行では旧0006形式の互換性、次の実行ではvector hydration障害時のkeyword fallback回帰を検出した。context列の互換projectionと独立した一括認可照合を追加し、既存テストを変更・弱体化せず最終全体成功を確認した。

100ページ検証は **合成テキスト・SQLite/Vectorize/Workers AI mock**。5ページ×20バッチで登録し、各バッチを再送して追加Embedding 0、100ページの保存・complete・readiness・source prepare冪等性を確認。実紙・OCR・実Cloudflare性能/検索品質の検証結果ではない。

そのほか：tenant isolation、folder/notebook scope、古いepoch/generation、同時CAS、除外後source ID変更、未登録document tombstone、Embedding直前撤回、Embedding/upsert中撤回、rerank中ロック、neighbor proof、Gemini再試行中失効、削除失敗とOFF中再試行、source/account削除、期限切れ旧writerと成功新writer、upsert成功/応答喪失、Worker終了時journal保持、schema部分欠損のfail closedを確認した。

## 独立レビュー

Plannerの実装前設計、Code Reviewer、Security Reviewerの実装後レビューを実施。
旧writer補償が新sourceを消す競合、upsert応答喪失時のID消失、Embedding直前の資格検査漏れ、document ID上限不一致を修正。再レビューで各修正を確認し、新たな指摘なし。ただし本番運用・外部サービスの保証は以下の残件を持つ。

## 本番前の残件・保証の限界

1. Worker強制終了による`settled=0`は永続保持する。削除再試行はできるが自動完了を主張せず、account削除は`deletion_busy`。監視・通知・安全な解消手順を設計する。外部状態未確認のままjournalを消す操作は不可。
2. 実Vectorizeで応答喪失/timeout時のmutation受理・deleteの適用順を検証する。[Vectorize操作は非同期](https://developers.cloudflare.com/vectorize/reference/client-api/)であり、mockの成功を即時物理消去の保証と扱わない。
3. iPad新同意・account別queue・安定document ID・5ページ/byte上限・中断再開・更新検知・OFF/失効状態・出典対応を実装する。初期は本人PDF・単一端末。
4. consentのfolder選択・既存/将来資料の説明、共有除外、未同期失効中の検索停止は端末実装と追加契約で確認する。server source IDを所有権証明や共有ACLとは扱わない。
5. 外部送信開始後の本文は回収不能。snapshot確認と送信開始をaccount coordinatorで厳密に直列化する機能は未実装。オフライン/複数端末の即時失効も保証外。
6. 同一generationの再送は再Embeddingを防ぐが、generationを切り替えた際のEmbeddingキャッシュ再利用は未実装。端末は不要なprepareを避ける。
7. staging migration/deploy、実API、日本語/OCR/代表100ページ、実iPad出典遷移、待ち時間/費用、回答目的の再調整・未使用問題・大量評価は後続工程。
8. プライバシー開示/新包括同意UIに対象範囲、外部送信・保存、停止/検索撤回/物理削除、削除待ちの違いを反映する。公開legalページは今回変更していない。

Projectの資料の更新が必要：`HYBRID_RAG.md`、`DATA_AND_MIGRATIONS.md`、`SECURITY_AND_PRIVACY.md`の複製。設計の`00_機能一覧と現状.md`と`01_意思決定ログ.md`、リリースの`00_残タスク表.md`/`02_審査メモ.md`に新API・同意・削除待ちと未デプロイを反映する。Desktopの複製更新とProject uploadは行っていない。
