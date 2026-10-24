# RAG staging検証記録（2026-10-09）

ユーザー承認によりRAG開発スナップショットをstagingへ配信し、合成100ページ資料を実binding／公開AIチャットで検証した。本番配信・有効化はしていない。

- 最終配信: `9f03da7e-8c3b-4d81-9e7e-bce0e0853e87`（100%）、2026-10-09 19:43:40 JST。
- 最終flag: RAG_ENABLED=false、AI_PROVIDER_APPROVED=false。一時Gemini APIキー削除済み。
- Vectorize ID取得を20件ずつに修正。対象15件／Worker800件成功、最終実環境65/65確認成功、独立レビュー指摘なし。
- 登録125.809秒、最後の登録からready観測70.669秒。同一PDFの再Embedding0。
- 検証所有者のsource／page／chunk0、FTS0、Vectorize0。再保存防止のhash削除バリアを維持。
- 5つの資料内質問で期待ページを取得。6問だけの試験で、出典の余分なページと反映直後の安定性は未解決。実紙OCR／実iPad／本番契約・申告・課金監視は未完了。
- migration／bindingの新規追加なし。0006／0007適用済みstagingを使用。
- 初回／第2試行の失敗と修正・復旧は[詳細報告](../RAG_100_PAGE_STAGING_REPORT.md)に記録。結果JSONと実装資料は同報告から参照。

ロールバックはflagをfalseへ戻し、削除コードとschemaを残す。実施・配信確認済み。以前の版`497cc667-88ea-423a-97f7-06b87aee0070`へのコードロールバックは未実施。

この環境は未コミットRAGを含む開発スナップショットであり、認証リリース候補の固定commitでの検証は別途必要。
