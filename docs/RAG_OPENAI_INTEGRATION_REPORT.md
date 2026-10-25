# RAGのOpenAI/Luna基盤統合（ローカル）

日付: 2026-10-13。作業先: .worktrees/rag-wip / codex/rag-wip。

## 目的と受け入れ条件

最新mainのOpenAI基盤を限定反映し、StandardのLunaへRAGを安全に接続する。検索/構造化出典/自動索引/削除/ユーザー分離を保持。旧Google/RAG同意のまま新提供元へ送らず、再試行前にも資料を再認可する。RAG無効・空・障害時は通常OpenAIのbodyと挙動を維持。最新mainの全認証/有料Standard/paywall移植は別作業であり今回行わない。

## 設計・安全・ロールバック

独立Plannerが依存、migration番号衝突、リトライ時の古い本文、ログ反射、旧同意を評価。main全体のmergeを避け、ファイルとコード箇所を限定した。変更前のdirty248ファイルをprivate一時領域に退避し、HEAD/main/バックアップを照合して既存RAG変更を保持した。

OpenAI Responses APIでLuna/Terra/Sol/Astraをプラン認可し、Standard既定はopenai-luna→gpt-6-luna。画像/採点/復習のmain OpenAI基盤も限定反映。credit take/giveはアカウント由来ハッシュに月/日/5時間/分の枠を用い、上流失敗・未完了を返却する。月枠は120/1500/4000、重みLuna1/Terra22/Sol20/Astra100。

openai-v1と年齢区分adult/teen、新rag-openai-v1を公開APIで検査する。旧rag-v1では検索資料をOpenAIへ送らない。撤回・削除・停止ルートは新同意なしでも利用可能。iOSの自動索引stateはaccount/endpointごとにprocessorConsentVersionを必要とし、旧stateを再開しない。従来のlocked/暗号化/ゴミ箱除外、Vectorize accountKey filterとD1 owner条件を維持する。

OpenAIへ送るinstructionsは各attempt直前の再認可から作る。HTTP応答後も出典を再照合。本文・prompt・Embedding元・上流エラー本文・例外本文をログへ出さない。未完了streamは完成通知を送らない。store:falseは応答の後日取得用保存の無効化であり、すべての保持や訓練の契約保証ではないと開示する。

AI_PROVIDER_APPROVED/RAG_ENABLED/RAG_AUTO_INDEX_ENABLEDは本番・stagingともfalseを保持。ロールバックはRAGだけOFFにして通常OpenAIを継続し、RAG削除・cleanupを残す。旧Google版へ戻して新同意を旧送信先に流用しない。既存migration0006/7/8は改名/適用せず、legacy paywall migrationも今回追加しない。本番最新paywallは未統合なので、この作業ブランチをそのまま本番へdeployしない。

## 評価runner

新 scripts/rag-quality/learning-openai-live.mjs はproduction handleAI + 固定ローカル合成retrieval + OpenAI。既定2対4回答（予約→回路、各explain→source_only）、最大6dispatch、60秒本文込み/6分dispatch期限/512KiB、固定URL/モデル/保存OFF、最初のエラーで全送信停止。6分は外部dispatchの期限で全体の後処理deadlineではなく、強制終了では途中結果が保存されない評価用制約が残る。モデレーションは固定合成probeのみoff（製品経路ではない）。比較対のinput/reference/config/citation一致を検査。OpenAIの完了イベント/返却モデル/usageを記録し、意味評価は手動pending、空patternはN/A。

CLIはSTUDIQUO_RAG_OPENAI_REMOTE=true、任意のSTUDIQUO_RAG_OPENAI_KEY_FILEへローカルsecret設定ファイルを指定する。キーはチャット・引数・出力・Notionへ貼らない。出力先は新しいprivateディレクトリのみ。旧Gemini learning-live CLIは退役し、新runnerへ誘導する。過去のGemini報告と結果は保持しLunaの成績に換算しない。

今回はローカル評価用OPENAI_API_KEYが見つからず、実OpenAI呼出しは行っていない。Workerに設定済みのsecretを読み出してはいない。実回答、usage/費用、品質改善の確認はキー設定後に行う。

## 検証

Worker全体1,184件成功（失敗/skip/cancel0）。iOS全ユニット1,624件成功（失敗0）。新OpenAI評価runner7件とlegal10件の対象も成功。独立Plannerによる実装後のコード/安全レビューでHigh/Mediumなし、最終独立対象58件成功。iOS RAG UI3件成功。初回の署名無効Keychainエラーは通常シミュレーター署名で解消、UIの画面外ボタンexistsによる早期スクロール終了はスクリーンショットで確認してisHittableまでスクロールへ修正し、状態/削除/出典の同じassertionを保った。git diff --check成功。モックの成功を実モデル精度として扱わない。実Cloudflare、実PDF/OCR、実iPadの評価は別途残る。

## 独立レビューと残件

独立レビューでiOSだけmainのpaywallを取り込み/api/planのないサーバーと不整合になる問題を指摘。SubscriptionStoreを作業前へ戻し、プラン表示はモデルとクレジット枠の必要変更だけに限定して解消した。store:falseの保存/訓練断定も修正した。審査・公開/外部契約は人間の別工程。

クレジットcounterのhashed利用量メタデータは期限後alarmで回収予定。最大40日窓で、窓終了後さらに同じ長さを足したalarm（初回takeから約80日後）が設定されるため、40日以内の物理削除を保証しない。現行mainと同じく削除処理はこれらの新counterを即時列挙purgeしない。学習本文は含まない。RAG本文/FTS/Vectorize削除の保証とは区別し、公開前の保持説明・運用確認の残件として記録する。

必要secret: OPENAI_API_KEY。非secretモデルvars: OPENAI_LUNA_MODEL=gpt-6-luna、OPENAI_TERRA_MODEL=gpt-5.6-terra、OPENAI_SOL_MODEL=gpt-6.1-sol、OPENAI_ASTRA_MODEL=gpt-6-astra。Workers AI/Vectorize/D1 bindingを維持。新DB migrationなし、適用/deploy/commit/push/mergeなし。

Project資料の更新が必要: HYBRID_RAG.md、ARCHITECTURE.md、SECURITY_AND_PRIVACY.md、legal-pages-source.js.txt。複製は変更しない。ストア原稿/審査メモと最新main資料の同期は別途確認する。

## 主要ファイル

変更: mcp-server/src/ai.js、openai.js、ai-privacy.js、rate-counter.js、entitlements.js、app.js、legal.js、wrangler.jsoncと関連テスト/評価helper。iOSはAIModelCatalog.swift、AIProvider.swift、ContentView.swiftのAI同意箇所、RAGIndexingService.swift、RAGLibrarySyncState/Service.swift、RAGControlsView.swift、RAGAutomaticLibraryControls.swift、SubscriptionPlansView.swiftと関連テスト。SubscriptionStoreは作業前に戻し、課金移行を除外した。
新規: ai-credits.js/counter-state.jsと関連テスト、PlanAllowance.swiftと関連テスト、scripts/rag-quality/learning-openai-live.mjs、rag-learning-openai-live.test.js、本報告。全dirty差分には今回以外のRAG/既存作業も含まれるためgit diffの全体を今回の変更として扱わない。

最終unit log: /private/tmp/studiquo-openai-rag-ios-final-tests.log（UI修正前の失敗も含む）。最終UI成功log: /private/tmp/studiquo-openai-rag-ios-ui-final.log。Worker最終log: /private/tmp/openai-all5.log。iOSビルド成功、XcodeGen再生成・Apple Sign In/CloudKit entitlements保持を確認。合成100ページ20batchと出典3ページ目の遷移を含むが、実PDF検索品質や実iPadの保証ではない。

今回の変更/新規ファイルの全一覧はRAG_OPENAI_INTEGRATION_FILES.json（開始前private backup、開始前HEADとの差分）を参照。

UI独立レビューは現行assertionとscroll修正を確認した。選択的バックアップにRAGCitationNavigationTests.swiftが含まれていなかったため、そのファイルのバックアップとの厳密diffは未取得。開始前statusで既存untrackedだったことを根拠に、変更一覧では新規ではなく変更として分類した。
