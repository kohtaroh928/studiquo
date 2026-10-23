# RAG出典修正のstaging再検証（2026-10-09）

承認済みの合成100ページ再試験を実施。配信前827テスト成功、実環境76/76確認成功。単純質問の出典は1ページ、7回同じ出典。比較の両主題は取得できたが蒸発・屈折の余分な出典が残る。実iPad／実紙OCRは未検証。

配信版 `3cb1bc6e-29cd-4906-9f00-d049e5a9bf85`、100%配信、21:53:26 JST。RAG／AI承認false、一時APIキー削除済み。合成所有者のsource／page／chunk0、FTS0、Vectorize0を確認。削除バリアは保持。migration／binding追加なし。本番変更なし。通常復旧はflag無効化と削除処理維持。

[詳細報告](../RAG_CITATION_STAGING_RECHECK_REPORT.md)を参照。認証リリース候補の固定commit検証を代替しない。
