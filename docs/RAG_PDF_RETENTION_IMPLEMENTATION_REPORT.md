# PDF保存情報の最小化：Step5-A実装結果

2026-10-19。High/full。`codex/rag-wip`でローカル実装・合成データ検証のみ。公開・remote migration・実データ削除・有料AI評価は未実施。

## 実装したもの

- 追加0014でjobのnullable `created_at`/`settled_at`、expiry/精算index、retention controlを追加。0010〜0013は変更せず、旧行はNULLのまま保持。
- reserveは新schema時だけcreated_atを記録。executor、明示未claim閉鎖、reaperの未claim精算の3経路で初回の状態遷移時だけsettled_atを記録。旧schemaでも取消・停止・精算を維持する。
- 精算起算はMAX(信頼済み捕捉時刻, DB SQL実行時刻の次秒)。遅いSQLで捕捉時刻だけが古くなるのを防ぎ、最大約1秒保守的に保持する。deadlineを精算時刻に流用せず、既存settled NULLの再送でも埋めない。DB時刻の健全性/過大未来clockの扱いはStep5-B/運用側でも必要。
- 内部`minimizeExpiredRawPDFIntakes`は`RAG_PDF_RETENTION_ENABLED === 'true'`と0014 policy/schemaが必要。現在configにflagを追加しておらず、HTTP/cronからも呼ばれない。失効後の安全な整理は主解析flagとは独立。
- 単一SQLで最大10行、期限切れpending/cancelledのrequest_id/PDF digest/長さを削減しcancelledにする。generation/intake UUID/owner-document/epoch/期限は保持。既存triggerは関連jobをstop_requestedにするだけで、job行・会計・未精算枠を削除/解放しない。
- 共通pass待機期限最大10秒。遅延DB書込み自体は取消できず、timeout後に完了し得る。原子的・冪等なSQLのみで、期限後に後続書込みを始めない。候補検索のpartial expiry indexをEXPLAIN/10000行の合成試験で確認。
- read-only operator集計は固定件数/経過時間だけ。ID/digest/token/生例外なし。全件集計の走査費用はあるため公開requestごとに実行しない。
- controlはphysical_purge_enabled=0をCHECKで固定。floor初期0、更新入口なし。単調UPDATE、DELETE禁止、既存singletonのINSERT/REPLACE禁止、旧admission INSERTにもfloor triggerを追加。これだけで将来の全purge条件を満たしたとはしない。

## 確認したこと

- 最終`npm test`: **1865 pass / 0 fail / 0 skip**。新retention専用14件を含む。期限境界、差替え競合、古いnowの遅延reserve、3精算経路/再送/遅延SQL、旧schema/NULL、全job状態の会計保持、flag/schema/DB失敗、上限・timeoutを検証。
- Wrangler SQL splitterで0001〜0014を適用するmigration回帰成功。
- 実local workerd/D1で14migration、新expiry UPDATE/triggerによる停止要求、job保持、DB精算時刻、aggregate、OR REPLACEによるfloor巻戻り拒否を確認。再現はmcp-serverから`node tools/rag-pdf-retention-local-smoke.mjs`。127.0.0.1と合成metadataのみ。一時保存先は終了時破棄。
- 最初のローカルruntime検証用scriptはconstructor適合修正後、sandboxのloopback権限不足で起動不可。許可済みlocal実行で検証した。remote配備の許可へ拡張していない。
- 実D1ではmeta.changesがtriggerのjob更新も数える差を検出。UPDATE RETURNING定数＋all()結果数へ修正し、intakeだけを正確に集計。修正後の全テストと実D1再実行成功。
- 独立Planner/Code/Security確認。時刻捕捉の早すぎる起算とINSERT OR REPLACEのfloor巻戻りを修正、再レビューで残所見なし。RETURNING修正も追加レビュー済み。reviewer自身によるテスト再実行はなし。
- `git diff --check`成功。過去Step1の374ファイルhash一覧は変更せず、今回の変更版は同伴RESULTS JSONの8ファイルhashで区別。過去テスト結果を新しい版の成績に流用しない。

## 配備・rollback・残件

0014を追加適用してから時刻記録/内部整理を検証する。旧WorkerはNULL時刻を作り得るが削除候補から外す。整理を止める場合は内部入口/flagを閉じ、0014列/control/floorと取消fenceは残す。DDL巻戻しや旧active状態の復元は行わない。

次はStep5-Bのclosed UTC窓＋settled_atから48h＋intake永続失効/置換＋参照/leaseなし条件、floor更新と旧writer互換、recovery child/job parentの原子的purgeと障害試験。Aには行物理削除・48h判定・floor前進・DO purge・account削除phase・receipt契約・scheduler有効化を含めない。Bは新しい独立設計/レビューを経て進める。

remoteは既存別系統配備/未適用migration/backup/承認、配布license/OS CVE、claimed停止不明の証拠付き復旧、receiptとiPad正式採用も残る。automationはPAUSED、commit/push/deploy/モデル変更なし。機能テスト成功は回答精度向上の評価ではない。

Project資料更新対象: DATA_AND_MIGRATIONS、SECURITY_AND_PRIVACY、HYBRID_RAG。複製/uploadは未変更。リリース00_残タスク表の従来残件も保持。
