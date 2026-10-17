# 原PDF自動解析の段階実装

2026-10-17。目的は、利用者が原PDFを選択すれば、Doclingの構造抽出から現在の構造索引まで接続できること。現在はprepared packageの同時選択が必要であり、この設計の全経路は未実装。

## 受け入れ条件

原PDF送信は既存のテキストRAG同意と分離する。認証済み本人・年齢/AI許可・原PDF用同意epoch・対象文書generationを確認する。処理中のロック、削除、同意撤回、account/endpoint切替によって結果を採用しない。解析serviceに索引登録権限やOpenAIキーを渡さない。原PDFをD1/R2/DOへ永続保存しない。処理失敗や部分資料は成功packageとして返さず、自動retryしない。

## 小さい実装単位

1. **有限ローカルrunner（今回）**: bytesだけを入力し、固定child entryから既存offline Docling→chunk→metadata→prepared exporterへ接続。子プロセスの120秒期限・取消・全process group停止とprivate一時領域の後片付け、10MiB/20page/4MiB結果上限。mock childで故障注入し、合成実PDFでも互換を確認する。HTTPや公開APIは持たない。
2. **private transport**: 固定HTTP契約、有限body readerとdeadline、busy/同時実行、切断取消、no-store、本文非ログ。Docker/Linux/model同梱は実buildで確認し、外向き通信と全job資源をcontainer側で制限する。loopback試験とCloudflare実環境を区別する。
3. **Worker admissionと原PDF同意**: header-only検証を用意し、JSON用privacy body readerへ原PDFを渡さない。canonical owner、同意epoch、文書generation、opaque job ID、上限予約、期限・状態のみ台帳へ記録する。処理前後の認可確認と失効・アカウント削除を接続する。原文台帳保存は禁止。
4. **iPad**: 原PDF選択中のbytesを新同意の後に送信し、返却packageをRAGStructuredDocumentでdigest/namespace/全page検証してから新Notebookへ保存する。既存Notebookに元PDFがない場合は再選択を求め、名前やpage数だけで関連付けない。
5. **限定稼働確認**: 明示的に承認された配備・費用範囲の下でLinux依存、モデル同梱、取消・強制終了、保持/削除、cold start、上限と品質を実測する。未確認で有効化しない。

## 設計上の選択

実行先の任意選択質問は回答待ちだが、既存Cloudflare内を前提にローカルの設計と可逆実装を進める旨を通知済み。配備・追加購入・公開の許可を得たとは扱わない。Containerへの接続はservice bindingに限定する案で、public fetchは拒否する。Container schedulingとSDKの対応は実装前に公式仕様を再確認する。

初版は20pageを上限にする。現在のprepared import上限100pageやlocal CLI上限1000pageを、そのままオンライン処理の性能保証に流用しない。ページ途中までの解析を成功にせず全資料拒否する。semantic vectorsなしのrecursive fallbackを明示し、実encoderや図/OCR/数式理解の能力を追加済みと扱わない。

## 脅威・障害・停止

PDFはネイティブparserを通る信頼しない入力。Python socket guard、process group kill、RLIMITは防御の一部で、OS sandboxではない。setsid等で離脱した悪意ある子、全jobメモリ・総ファイル数・ネットワークはコンテナ等の境界が必要。親プロセス自体の強制終了時はfinally実行を保証できない。HTTP提供前に単発jobの隔離、起動時残存掃除、プロセス/VM破棄、admissionが必要。

cleanup失敗は成功を返さず固定errorにする。本文/パス/外部parser errorをログ・public errorへ入れない。root領域や設定パスをrequestで切り替えさせない。runtime/modelの準備・追加取得は別の操作で、自動downloadしない。

rollback: 未接続unitの追加中は既存アプリ/Workerに影響しない。接続後は受付flagで新規jobを停止し、失効/cleanupを継続する。既存の認可guardを除いた旧Workerへの巻戻しはしない。公開実装前の配備手順・ロールバック確認は別工程。

## 現在の状態

finite runnerのローカル実装・19テスト・独立review・実合成2page確認を完了。詳細はRAG_DOCLING_PROCESSOR_REPORT.md。privateHTTPのloopback限定実装・23テスト（processor含む42）・実合成PDF通信確認を完了。private Container RPC/DO制御とcontainer入口・Docker recipeのローカル実装を追加（RAG_DOCLING_CONTAINER_BOUNDARY_REPORT.md）。既存MCPへのbinding、実Linux/Cloudflareでの隔離・起動/停止、rawPDF公開route/同意/admission、iPad自動parseは未確認・未接続。自動スケジュールPAUSED、新有料API/鍵アクセス/remote変更なし。
