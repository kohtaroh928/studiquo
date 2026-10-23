# hidden-conditionの時間切れ解析（2026-10-11）

**直接の原因は、HTTP応答ヘッダーを取得・観測できないまま評価側の5秒制限が発動したこと。** 資料選択の不正出力やJSON解析エラーで失敗したのではない。同じ入力・設定を診断用に再測定すると3.040秒で正常完了し、恒常的な入力・schemaの不具合は再現しなかった。元の遅れが通信とGemini側のどちらによるものかは確定できない。

## 元の記録から分かること

元のhidden-conditionは5.006秒、reason=timeout、HTTP status・finishReason・usage・modelVersionはいずれも未取得だった。`runParagraphProposal`の5秒timerがAbortControllerを中断してbaselineへ戻す。通信adapterはfetchが応答を返した直後、本文解析前にHTTP statusを観測する。status未取得なので、元の5秒の間はHTTP応答ヘッダーが観測されていない。

これはGoogleからHTTP504等のエラーが返った記録ではなく、クライアント側の打ち切りである。出典や条件を選び間違えた結果でもない。ただし、打ち切り後にGoogleが返した可能性のある状態や、サーバー側処理・課金の停止は保証できない。

## 診断方法

対象と同じprotocol2 prompt・schema・Gemini3.6・temperature1・minimal thinking・maxOutput4096を使用し、診断deadlineだけ20秒へ延ばした。元のadapterが送る対象リクエストと本文が完全一致することをテストで確認した。前後に同じ2参照の小さい合成対照質問を置き、31秒間隔、最大3call、逐次、retryなし、認証・429・5xxで即停止した。

モデルからのHTTP応答ヘッダー到着時刻と、本文受信・解析・形式検証を終えた時刻を分けて記録した。非streamingの応答待ちには、接続・ネットワーク・Google側の処理待ちや生成が混ざる。headersMsだけからDNS・TLS・モデル混雑を単独で特定できない。対照と対象は内容も違うため、原因を一要因へ固定する実験ではない。

## 実測

| 要求 | HTTPヘッダー到着 | 完了 | 本文等の処理差分 | 結果 |
| --- | --- | --- | --- | --- |
| 小さい対照・前 | 1.308秒 | 1.310秒 | 約2ms | HTTP200、STOP、形式有効 |
| 同じhidden-condition | 3.039秒 | 3.040秒 | 約1ms | HTTP200、STOP、形式有効 |
| 小さい対照・後 | 2.087秒 | 2.088秒 | 約1ms | HTTP200、STOP、形式有効 |

3要求ともmodelVersion `gemini-3.6-flash`。対象のrequest bodyは2,360 bytes、対照は2,295 bytes。対象入力348 tokens、対照各340 tokens。対象出力119 tokens、対照各122 tokensで、明らかに大きい入力や大量出力ではない。MAX_TOKENS・quota・5xxエラーは今回観測していない。

今回の本文処理は約1〜2msで、本文解析が遅いという証拠はない。対象が再測定で5秒より短く完了したため、内容やschemaが常に時間切れを起こすという仮説は支持されない。応答待ちの一時的な変動が考えられるが、元要求の接続情報・Google側traceはなく、混雑・通信・生成時間のどれかを断定できない。

20秒の診断設定での成功は、元の5秒評価の失敗を成功へ書き換えるものではない。形式の確認のみで、新しい選択全文・witnessの意味品質は計測していない。再開状態も変更せず、hidden-conditionは引き続き正式5秒評価の未完了として残す。

## 今回の変更と検証

- 新規 `mcp-server/scripts/rag-quality/paragraph-timeout-diagnose.mjs`: 固定3要求、診断専用20秒、hash/bytesと時刻を記録。
- 変更 `gemini-isolate.mjs`: headersMs・completeMs・phase、protocol2の検証関数を追加。既存protocol1のdefaultを維持。
- 新規 `src/rag-paragraph-timeout.test.js`: 元要求一致、時間切れの位置、遅い処理で保存値が変わらないこと、停止・非漏洩等の11回帰。
- 新規本報告と `RAG_TIMEOUT_DIAGNOSTIC_RESULTS.json`、`HYBRID_RAG.md`と評価READMEの更新。

関連51テスト、全サーバー1,019テスト成功（約44.7秒、失敗・skipなし）。独立コードレビューで新規11＋既存10を再実行して成功、独立安全preflightも問題なし。数値・結果解釈の独立レビューも完了し、HTTP応答の物理到着ではなくヘッダーの観測を根拠にする表現へ修正した。差分の空白検査も成功。iOS・実iPad・OCR・100ページPDFは再検証していない。

キー・資料本文・prompt・モデル生JSON・自由エラー文を保存していない。今回の診断3callのusage合計は入力1,028・出力363・total1,391 tokens。実請求額・billing tierは未確認。元のtimeout callのusage/課金は不明。

## 対応方針

今回、製品の待ち時間やモデル設定は変更していない。診断だけの成功を理由に本番の制限を20秒へ伸ばさない。まず正式な5秒条件で未完了1問を別測定し、複数段落資料でも確認する。その後、許可した小さい回数の測定で応答時間の変動を見て、処理全体の時間予算とfallbackを含めて待ち時間を決める。

[Googleの公式troubleshooting](https://ai.google.dev/gemini-api/docs/troubleshooting)は、クライアントとbackend両方の問題、thinkingによる遅延や、再試行回数の上限を設けることを説明している。今回すでにminimal設定を使っており、thinkingが元の時間切れ原因だったという証拠はない。quotaの大量再試行を解決策にしない。

deploy・migration・binding・課金設定・公開flag・プライバシーポリシー変更なし。ロールバックは診断scriptとisolateへの追加時刻/validatorを戻す範囲で、サーバー操作は不要。Projectの設計資料 `HYBRID_RAG.md` の差し替えが必要。複製置き場は変更していない。
