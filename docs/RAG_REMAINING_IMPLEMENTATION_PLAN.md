# RAG残実装の継続計画

2026-10-17。ユーザーの自動進行依頼に基づく。通常の実装判断は進め、公開操作・追加購入・新有料評価は含めない。自動スケジュールはPAUSED維持。

## 順序と完了条件

1. iPadで引用metadataを受信・保持。旧出典との互換、不正metadataの安全なページ表示へのfallbackを検証する。
2. 原PDFとprepared Docling packageを同時選択し、bytes digest一致で新Notebookへ取り込む。既存Notebookにタイトルやページ数で紐付けない。端末検証と実Docling→Swift互換を確認する。
3. packageをSwiftData optional属性へ保存し、Notebook暗号化payloadへ含める。ロック時の平文消去・復号・旧暗号文互換・編集後失効を検証。副ファイルやUserDefaultsに資料本文を置かない。backup/copyはpackageを暗黙継承しない。
4. manual/managed索引を共通の構造payloadへ接続する。元のowner/epoch/generation/fingerprint/同意再確認を維持し、変更された手書き・画像を古いpackageで隠さない。旧アプリ/旧Workerへの送信条件を確認する。
5. 引用の表示を検証する。page/sourceの認可は既存resolve、metadataは位置の補助のみ。元PDF寸法/crop/rotationが確定しないbboxで精密ジャンプを捏造しない。
6. 原PDF自動解析基盤へ接続。Python実行先の選択をユーザーへ非同期確認済みで回答待ち。十分な待機後、既存Cloudflare内を暫定前提としてローカル設計・実装へ進む旨を通知した。原PDF外部送信の別同意・費用/保存/障害制御・稼働基盤の確認が必要。稼働環境未選択のままdisabled bindingだけを追加して自動接続完了とは扱わない。
7. 実encoderの自動意味分割、図/スキャン/数式の要確認解除、実資料品質、iPad総合動作を別の能力として検証する。未知要素を黙って除外せず、精度向上をテスト件数だけで主張しない。リランカー候補は選定・比較段階で、比較なしのモデル交換は行わない。

## 制約

原PDF通常importはpage画像/native textだけを保持しており原bytes/hashは無い。自動Doclingで既存資料を再処理するには原PDFの再選択などが必要。Prepared importは本物のDocling結果を使う経路だが、自動解析そのものではない。

新prepared importは最大100pages/各辺1..4096points/4MP描画/PNG累計128MiBでbounded。package自体の検証上限1000pagesとは分ける。新fieldはCloudKit互換optional、サーバーmigrationや本番反映なし。公開順・rollbackはRAG_STRUCTURED_INGESTION.mdを参照。

2026-10-17: 1〜5のローカル実装・関連検証を完了。実機総合UI/旧実store/iCloud検証と精密bbox遷移は未実施。6の初単位は有限Python runnerとprivate transport契約から実装する。詳細はRAG_IPAD_STRUCTURED_INTEGRATION.md。

2026-10-17: 6の最初の有限local runner単位を完了（19tests/独立review/実2page）。HTTP/private transport/原PDF同意・admission・アプリ自動接続は未実装。詳細RAG_DOCLING_PROCESSOR_REPORT.md。


2026-10-17: private HTTP local adapterを実装・検証。transport23+processor19=42成功、独立review42成功、既存Docling49成功。実合成2pageをHTTP→Docling→prepared検証まで確認（8477byte/8.43秒/全job削除）。cleanupfailed停止/再cancel待機/start-close競合/二重応答/shutdown取消順を修正、High/Medium残件なし。詳細RAG_DOCLING_PRIVATE_TRANSPORT_REPORT.md/RESULTS.json。loopbackのみでCF/原PDF同意/認可/admission/OS隔離/アプリ自動接続は未実装。次はcontainer/private bindingの実行境界設計。配備/追加購入/外部API/鍵/モデル取得なし、自動スケジュールPAUSED。


## Doclingのprivate Container実行境界（2026-10-17、未配備）

独立services/docling-workerにprivate RPC/default flag false、単発jobの期限・取消・非本文状態・destroy後返却を実装。Container専用Python入口、ready前版/model検証、有限no-follow orphan cleanup、offline/nonroot Docker recipeとsample configを追加。既存MCP/iPadは未接続。JS28・Python関連60/既存49成功、型生成/bundleと合成2pageの実Nodefetch→Docling接続を確認（VMlifecycleはmock）。Docker不在でLinux build/実Cloudflare起動・隔離・停止は未検証。原PDF別同意/認可/admission・削除/予算・運用監視と依存監査を満たす前に有効化しない。DO stateはopaque ID/status/deadline/cleanup回数のみで本文なし、tombstone retentionは未設計。storage障害でpoison/alarm保存できない場合は運用停止確認が必要。詳細 [RAG_DOCLING_CONTAINER_BOUNDARY_REPORT.md](RAG_DOCLING_CONTAINER_BOUNDARY_REPORT.md)。公開操作・追加購入なし、自動スケジュールPAUSED。
