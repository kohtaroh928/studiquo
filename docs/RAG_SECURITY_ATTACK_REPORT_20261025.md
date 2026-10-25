# RAGローカル攻撃試験 2026-10-25

対象: main 7a16648、codex/rag-security-attack。実装変更なし。

既存rag-safety/integration/output-filter/redact-pii/injection-hints/pdf-authorizationの6試験ファイル: 101成功、失敗0、skip0。所有者/範囲偽装、失効、リンク難読化、マスクの回帰を実行。初回は依存zod未解決で3ファイル起動失敗、既存node_modulesへのsymlink後に全成功。

追加の合成データ動的プローブ: qualityEnvironmentのAI.runを記録するモックで、合成メールを含む資料を登録してretrieveを実行。rerankCalls=1、rawSyntheticEmailSentToReranker=true、rawEmailInFinalContext=false、status=grounded。マスク前の情報がrerank呼出し引数へ渡る点を再現。実外部送信は行っていない。

限界: 実LLMの指示注入成功率、実D1/Vectorize、本番構成、PDF処理VM、実機は未検証。101件成功は実モデルへの注入耐性を保証しない。

次の一手: rerank前のマスク適用を検討し、合成悪意資料での実モデル評価を別途実施。GitHub Projectはunknown owner typeで未記録。秘密/個人/学習データは使用なし。試験時点ではdeploy/push/commitなし。その後ユーザー依頼で本報告と引き継ぎをコミット・ブランチpushする。
