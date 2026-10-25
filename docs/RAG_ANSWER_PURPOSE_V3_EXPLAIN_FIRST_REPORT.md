# 回答目的v3・解説優先の実API確認

日付: 2026-10-12。作業先: .worktrees/rag-wip。未公開。

## 結果

予約explain→source_only、回路explain→source_onlyの2対4回答を計画。接続可能な環境では最初の予約explainへの1送信でGemini HTTP503（2,248ms）。完成回答0、完成対0。後続3回答、内部retry/fallback、追加の実API評価は停止した。v3補足表示と条件・例外の保持は評価不能。プロンプト修正の成功・失敗や汎用精度を判断しない。

要求モデルgemini-3.5-flash。返却modelVersion、usage、確定請求は不明。ローカルproduction handleAIと固定合成retrieval、実Geminiの評価であり実Cloudflare検索、実PDF/OCR、iPadの検証ではない。Worker側の最終HTTP500と上流Gemini503を区別する。503の詳細原因は未特定。

## 接続の切り分け

最初の制限環境ではHTTP応答なし、12msで通信失敗。APIキーを送らない接続確認で名前解決失敗を確認した。ネットワーク制限外の確認ではGoogleへ到達（ルートURLのHTTP404）。したがって制限環境の失敗はGemini503の評価に含めない。接続可能な環境で上記1回を実施し、上流エラーで停止した。03と04の別privateartifactを作り過去結果を上書きしていない。dispatch数はfetch試行数であり、03の外部到達は確認できない。

## 検証・保存

runner対象10テスト成功、失敗/skip0。今回は製品コード・プロンプト・設定変更なし。前回の全Worker1,134成功を今回再実行したとは主張しない。iOS再テストなし。

原本は/private/tmp/studiquo-learning-live-20261012-03および04にprivate保存。repositoryのRESULTSは許可したmetadataのみで、APIキー、回答本文、prompt、上流エラー本文なし。本番・stagingのdeploy、migration、push、merge、commitなし。両RAG flags変更なし。

## 残件・次の一手

Gemini503の限定的な原因切り分けを先に行い、利用できる条件を確認してから同一v3の解説優先比較を再開する。モデルや生成条件を変える場合は別評価として記録する。W01/W03の単位・不要代入、W61/W62の目的と補足境界は未解決。実検索・実機評価も未実施。

製品変更なしのためロールバック不要。Projectの資料の更新: なし（評価報告はPROJECT_SYNCで複製対象外）。Notionに結果と残件を記録する。
