# Project資料更新とRAGテスト再開

2026-10-17。基準branchはcodex/rag-wip、開始commitは09e2a7e。

## Project資料

Desktop/studiquo-projectsの18ファイルを更新。設計/データ/安全性/HYBRID_RAG/INDEX、legal source、過去のRAG staging記録、機能一覧/意思決定/残件/申告/審査/プランとREADMEを同期した。11複製は正本とbyte一致を確認。元版はprivate tmpに退避、人物像の手記用ファイルは変更していない。更新一覧とSHA256はRESULTS.jsonに記録した。

回答生成先OpenAI、Standard既定Luna、月120/1,500/4,000クレジット、構造維持＋本文の意味境界/再帰分割、実encoder未接続、原PDF自動解析未接続、metadata migration0009未適用、未公開状態を区別した。Standardのアプリ無料表示とWorker standard.yearly対応の差は、今回決め直さず公開前の整合残件として記録した。その他分野の古い未確認事項を完了にしていない。

claude.aiへのアップロードは未実施。docs/PROJECT_SYNC.mdに従い、人間が既存Project内の古い同名資料と差し替える。Desktop用の編集はリポジトリ内の製品仕様変更とは別である。

## 再開したテスト

- 署名付きiPad Pro 13-inch M5 / iOS26.5 simulator: 関連12suite・134件成功、失敗0。構造package/原PDF照合、抽出・索引・編集失効・ライブラリ同期・出典metadata・有限stream・暗号化・AI同意・モデル/クレジット設定を確認。
- RAG UI: 3件成功、失敗0。保存済み検索データ管理、検索状態の表示/未知状態非表示、出典から3ページ目を開く操作を確認。
- 既存の合成回答coverage replay: 外部API0回。開発30問の60台帳を維持し、保存済み24回答のうち差分要求8回答の固定注釈を再確認。記述あり5、欠落3。probeは明示候補3/欠落候補3/要review2。今回出力の全fieldは既存報告と一致（既存報告の追加sourceHashes/verificationを除く）。

coverageは過去4候補の固定回答・既存注釈の再現確認であり、現在のLunaや本番RAGの合格率ではない。新回答生成・未使用20問による調整・有料API評価はしていない。本番promptを変更していない。

## 限界と次の一手

実アプリのテストは現在のworktreeで実施した。以前からのContentView/StudiquoApp等の無関係な未コミット差分は保持しており、今回アプリのコードを変更していない。シミュレーターにiCloud accountが無い旨の起動ログがある。関連assertionは成功したが、実機・旧実store・iCloud移行の検証にはならない。

サーバー/Doclingの全回帰は直前のpush時に成功済みで、同じ未変更コードの全テストは今回繰り返していない。137成功はアプリの回帰結果であり、検索・回答精度向上の証明ではない。Linux/実Cloudflare、原PDF別同意・認可・admission・取消削除とMCP/iPad接続、意味encoder、図/OCR/数式、実資料品質の残件は維持する。

次の回答品質検証は、開発問題の要求項目と出典対応を確認し、版・条件を固定した新回答評価として扱う。過去回答の再現と新しいモデル回答を混ぜない。必要な費用・モデル・件数を確定してから実APIへ進む。自動スケジュールはPAUSED、deploy/remote migrationはしていない。
