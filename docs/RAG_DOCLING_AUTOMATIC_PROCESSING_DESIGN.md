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

## 原PDF受信の前処理単位（2026-10-18）

目的は本文をJSONとして読まず、有限のPDF bytesだけを受け取る内部部品を準備すること。独立Planner確認済み。公開route・binding・DB・アプリは接続しない。

受け入れ条件: 3つのRAG/PDF flagが文字列true、既存AI同意/年齢、RAG同意、別の原PDF同意を本文取得前に確認。application/pdf・非圧縮、任意のContent-Length（5〜10MiBの整数）を検証。実bytesを上限10MiB、全体10秒、%PDF- signature、宣言長一致で検証し、取消/読取エラー/停止でも有限終了する。既存JSONの判定順と応答を維持する。

脅威と境界: 同意ヘッダーは自己申告であり本人認可・永続同意epoch・文書generation・費用予約を保証しない。公開接続前に別途必須。signatureはPDF安全性/ページ数の保証ではない。巨大chunk生成そのものやプラットフォーム強制停止はreaderで保証しない。ログへ本文や入力ヘッダーを出さない。停止したcancel promiseを待ち続けない。rollbackは内部部品を未接続のまま維持し、共通AIヘッダー抽出のみ既存回帰テストで確認する。

参照: [Cloudflare Workers best practices](https://developers.cloudflare.com/workers/best-practices/workers-best-practices/)、[ReadableStream](https://developers.cloudflare.com/workers/runtime-apis/streams/readablestream/)。

実装結果: aiPrivacyHeadersRejectionを抽出し、rag/pdf-preflight.jsにheader-only確認とreadRawPDFBytesLimitedを追加。受信上限10MiB・全体10秒に加えread操作65,536回で微小/空chunk floodを制限。固定buffer＋現在readのinterrupt callbackのみ保持し、未解決共通Promiseへのreaction累積を避ける。cancelは拒否を観測するが完了を無期限待機しない。返却コピーとbufferが一時共存する最大約20MiB/呼出しは将来admissionで考慮する。タイマーはOS強制期限ではなく、実Workers受信/切断は未検証。

独立Code/Security review: reaction累積指摘を修正後、未解決所見なし。Securityが対象23件を独立再実行成功。公開route/binding/configへのimport/flag追加なし、Docling実送信・保存・課金・新有料評価なし。次工程は本人・文書世代・永続rawPDF同意epoch・利用枠の予約と取消削除を接続前に実装すること。

最終検証: 対象23件、サーバー全体1,736件（失敗/skip 0）、git diff --check成功。今回の実行process完了、Notion既存RAGカードの結果・次の一手と共通引き継ぎを更新済み。未commit/push。

## 永続rawPDF同意・文書認可単位（2026-10-18、実装前設計）

原PDF同意は独立tableでepoch/enabled/RAG同意epochへのbind/versionのみを保存する。認証済みsessionのsubからcanonical account keyを計算し、任意のaccount keyは受け取らない。RAG同意変更・削除とaccount tombstoneはDB triggerで原子的にraw同意を無効化しepochを増やす。古いpayload、撤回後の再許可、account削除途中失敗→再登録でも旧raw同意は復活させない。無効化はflags offでも可能、付与のみflags/現行RAG同意を要求する。

受け入れ条件: 新migration0010は追加型・ローカル検証のみ。schema不在はraw処理を拒否、既存経路は互換。CAS同時更新は1件のみ成功。他人/欠落/ロック/世代変更/旧同意は単一owner-scoped JOINで一様拒否。文書sourceHashは既存抽出textのsnapshotでありrawPDF SHA256の検証ではない。原PDFbytesのbindingと新規Notebookのprepare導線、admission/費用予約・job取消/削除・送信前後再確認・公開route/iPadは別工程。今回guardの成功を処理開始許可全体としない。

rollback: route/binding未接続を維持。適用後0010の表/triggerは削除しない。旧Workerもtriggerにより同意撤回/削除でraw権限を落とす。schema障害は閉じて失敗し、SQLや本文を返さない。guardは単一statementの時点確認であり後続処理のleaseではない。primary ADMIN_DB bindingを直接使い、読取replica Sessionを渡さない。並行失効の送信窓を完全に消す保証はしない。

実装結果: 0010の追加table/3triggerとpdf-authorization.jsの内部CAS/read/guardを追加。payload/proofを非同期前にコピーしDBエラーを固定化。独立Planner/Code/Security確認、未解決指摘なし。対象最終30件・独立Security18件成功、サーバー全体1,752件成功（全体run開始後追加の競合/不正入力2testは対象30件に含む。コード同一）。実D1競合/trigger配備は未確認。migration未適用・公開未接続・実PDF送信なし。

次の一手は新規Notebook向けintake文書・generation・rawPDF digest予約。現guardは既存registered文書のtext hashしか検証しないため、新規原PDF経路を完成扱いしない。予約/admission/job取消削除/送信・結果採用前再認可は続く工程。Notion既存カードと共通handoff更新済み。Project複製対象: DATA_AND_MIGRATIONS/SECURITY_AND_PRIVACY/HYBRID_RAG。置き場は未更新。

## 新規原PDF intakeとbytes同一性（2026-10-18、実装前設計）

解析前は本文sourceHashがないため、既存rag_documentsとは別のintakeを予約する。canonical owner/文書ID/世代/サーバーUUID/requestID/原PDF SHA256/bytes長/両同意epoch/サーバー期限/状態のみを保存し、本文・名前・PDFは保存しない。初期期限は10分。厳密に同一requestの再送のみ同じ予約を返し、期限は延長しない。差し替えは期待世代CASで新UUID/世代へ進む。取消・親同意失効でpendingを無効化しdigest/長さを消す。撤回後再許可やaccount再登録で旧予約を復活させない。

受け入れ条件: 同意とaccountが現在有効な場合だけINSERT/UPDATEする。欠落/他人/旧世代/期限切れ/取消を単一JOINで拒否。bytes検証は有限reader後のUint8Arrayだけを受け、長さ/signature/SHA256を検証し同意/予約を再確認する。非同期処理前にproof/payload/bytesをコピーし変更競合を防ぐ。期限/時刻は信頼済み呼出元のserver clockのみ。readerへの接続はadmission完成後とし、今回HTTP bodyを読む関数は追加しない。

この部品はjob claim・費用予約・処理leaseではない。同じ予約での同時検証を解析重複防止としない。新規予約数/rate limit/全体並列メモリ/台帳保持整理・処理job取消/削除・結果のNotebook採用は次工程の公開前必須条件。DB障害は固定errorで閉じる。migration0011は追加型・ローカル検証のみ、表/triggerを破棄するrollbackはしない。実D1のtrigger連鎖/競合は公開前に別確認する。

実装の選択: 単位を受付・snapshot・bytes検証へ絞り、reader接続とreserved→receivedの一度限りclaimは次のadmission/job単位へ回す。行はowner/documentごとのcurrent＋世代tombstone方式で、全generation/requestの履歴を複製しない。元expectedGenerationの旧request再送は拒否するが、過去request IDを新期待世代で意図的に再使用することの永久禁止は保証しない。これを解析job再実行可否と混同しない。既存rag_documentsはNOT EXISTSで拒否し、同tableのinsert/update/deleteとraw同意bind/version変化・削除、account物理削除も失効triggerの対象にした。TTLは認可期限であり自動消去期限ではない。

最終検証: intake21＋認可18＋preflight13の52件、サーバー全体1,775件成功（失敗/skip 0）。独立Code/Security観点レビューの残指摘なし、独立再テストは未実施。git diff --check成功。今回process完了、Notion既存カード・共通handoff更新済み。実D1/実PDF/配備検証なし、0011未適用・公開未接続。

## Step1・2: 利用枠と実行job（2026-10-18、実装前設計）

受信前の予約と一度限りreceive claimを分離する。reserve再送は同じjob IDのみ返し、秘密実行tokenはclaim勝者に一度だけ返す。token hashをDBへ保存、同tokenでreceiving→dispatchedを一度だけCASする。dispatch前にDBで不可逆印を付け、通信失敗で開始有無不明でも再dispatchしない。状態はreserved/receiving/dispatched/stop_requested/settled。失効・差替え・取消でstop_requestedへ進むが、期限切れや取消要求だけでは枠を解放しない。

設定は信頼済みserver policyを必須にし、未設定時閉じる。固定UTC日窓のowner/global受付件数と予約単位、active slotと保守的64MiB/件のmemory weightを単一INSERT条件で確認する。64MiBは会計上の保守的weightでありheap上限の実測保証ではない。policy/予約単位/weight/窓はjob作成時に固定し、既存jobを新設定で安く再評価しない。利用単位は未実測の金額や既存AI creditsではなく、Docling受付用の内部上限。

取消/同意失効/intake差替えはDB triggerでjobをstop_requestedにする。未claimはtokenが発行されないため条件付きで安全に終了可能。claim済みは信頼済みexecutorが受信/解析/cleanup停止を確認し、対応tokenで精算して初めて枠を解放する。dispatch済みは常に予約単位を保守的に消費（実請求/返金ではない）、未dispatchは停止確認後0単位に精算。同じ精算は冪等、取消やflags offでも使える。

今回の受入条件は、同時reserveで上限超過なし、同intake一job、receive/dispatch勝者一件、失効後新claim不可、期限切れで枠復活なし、停止不明/DB障害で枠保持、二重精算で予算復活なし。公開route/reader/実Docling cancelやdispatchへの接続は別工程。DB外の停止確認をclient入力として受け付けない。retention/監視/自動reaperは未接続。rollbackは表/失効/精算記録を残し受付を閉じる。remote適用・有料呼出しなし。

実装結果: 0012/pdf-jobs.jsの未接続状態機械と17新テストを追加。claim前に何度reserve再送してもtokenは再発行せず、receive claimとdispatch各1勝者、失効/停止要求と精算CASを実装。global/ownerの窓内件数・units・active/memoryは保存済みrowで計算し、日窓が変わっても未停止active枠は維持。flags off/同意撤回後も停止要求・精算は使用可能。独立Code/Security観点レビューの残指摘なし。

残件: 本文受信やVM停止への実接続、自動監視/reaper/cleanup retry、停止不明・token紛失時の証拠付き復旧、台帳retention、intake予約API自体のrate/保存行数制限、実D1競合、memory profiling、実費に基づくpolicy校正。今回はshadow budgetであり実請求や返金の保証ではない。未実装を含めStep1/2全体完了とはしない。運用設定は書き込まず未設定時拒否、公開/配備/有料runなし。

最終検証: 関連69件、全サーバー1,792件成功（失敗/skip 0）、git diff --check成功。独立Code/Security観点レビューの未解決指摘なし（独立再実行なし）。今回process完了、Notion既存カード/共通handoff更新済み。公開/実VM/remote適用は未実施。

## 内部orchestrator接続（2026-10-18、実装前設計）

順序: header/binding確認→予約→receive claim→job/intake監視→有限reader→bytes検証→dispatch CAS→parse一回→strict manifest→再認可→停止確認精算→返却前intake再確認。claim敗者は勝者を取消/精算しない。job側だけの停止要求もtoken付きguardで検知する。DB待ち中にもwork deadline/abortを独立発火、監視pollは重ねない。workは最大job残期限、cleanup/精算は別の最大10秒grace。

正常private parseの解決は既存serviceのdestroy後返却契約によりVM停止確認として扱い、正常終了へ重複destroyしない。開始不明/parse失敗/中断は固定binding.cancel(jobID)を一回呼び、厳密なcancelled:true確認だけ停止成功とする。RPC待機timeoutそのものを停止成功としない。ローカルreaderのcancel完了も有限待機で観測し、未確認なら枠を保持する。停止後にparseが遅れて解決しても公開せず再実行しない。

resultは4MiB以内のstrict envelope/全page連番/原PDF digestと共通document/namespace、既存最終structure validator、全batchのlocal ID一意を確認する。validation成功を任意metadataの認可としない。公開route/アプリ/実bindingは未接続、実Linux/VM検証はDocker/Podman不在で未完。内部合成testでmockと実基盤を区別する。

## 停止再試行の現在地（2026-10-18）

0013/recovery内部reaperと集計を追加。各DB段階/停止RPC候補最大10件、pass10秒、RPC待機2秒、lease30秒、合計3試行。未claimだけ0精算、claimedはremote停止確認後も枠/units保持。元executor精算後にdoneへ。独立Code/Security観点reviewに未解決指摘なし、関連13/全サーバー1,825件成功。公開route/scheduler・実D1/VM・retention/停止証拠付き自動回収は未完。詳細は[RAG_PDF_RECOVERY](RAG_PDF_RECOVERY.md)。

続くiPad正式採用のmetadata/receipt/registry移行は[RAG_PDF_ADOPTION_DESIGN](RAG_PDF_ADOPTION_DESIGN.md)に独立Planner調査を記録。設計のみで、本文staging/転送/新Notebook保存へは未接続。intakeを無効化するregistry triggerを外さず、移行後の文書認可へ切り替える。

## 2026-10-18 実Linux・公開HTTP接続（最新）

実Linux amd64コンテナで合成2ページを解析（22.908秒）、通信遮断・UID10001・非書込コード/モデル・取消・期限切れ・SIGTERM・job削除を確認。認証済みローカルworkerd→private RPC→同Linux Docling→最終complete/精算も21.045秒で成功した。Cloudflareへの配備・remote migration・公開URL有効化は未実施で、ローカル成功をremote完了とは扱わない。

公開HTTP handlerは認証後に同意/intake/process/cancelを処理する。受信前認可・予約、転送中の再認可、停止精算後のcompleteを維持。早すぎるResponse返却によるworkerdの入力破棄、isolated Pythonの兄弟import、WranglerのCASE分割を実環境で修正。受付/cleanup/private実行flagsはfalse。本番private bindingなし。staging設定とdry-runを準備済み。

検証: サーバー全1,851件、processor61件、provision6件、HTTP/app/process42件成功。Python102依存のauditは既知脆弱性0・skip0（OS/モデルライセンスの保証ではない）。独立Code/Securityレビューの未解決所見なし。回答品質の有料評価・実資料・未使用20問は使っていない。

詳細・制約・ロールバック: [実Linuxと公開接続の検証](RAG_LINUX_PUBLIC_CONNECTION_REPORT.md)。次はstagingの既存配備/DB状態と利用条件を確認し、remote配備の承認範囲を確定してから段階適用・疎通する。iPad正式採用、claimed停止不明の復旧、retentionは残る。
