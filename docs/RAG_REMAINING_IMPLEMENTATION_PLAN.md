# RAG残実装の継続計画


## 残タスクの実行順（2026-10-19、最新の棚卸し）

目的・既存9段階は維持し、以下を次の具体単位とする。後半の「Dockerなし」「公開HTTP未接続」「転送方式未確定」は過去記録。実Linuxとlocal workerd通し・NDJSON転送は実装/検証済み、remote配備・iPad正式採用は未完。今回は棚卸し/計画更新のみで、配備や新有料評価を実行/承認したものではない。

| 順序 | 小タスク | 完了の確認 |
| --- | --- | --- |
| 1（完了） | 既存dirty差分と公開commitの差を整理し、ローカル検証候補の版を固定 | 374ファイル/集合hashを固定・独立照合。不変archive/配備許可ではない。[記録](RAG_VERIFICATION_BASELINE_20261019.md) |
| 2（調査完了） | Cloudflare stagingの既存版・DB適用済みmigration・契約/料金条件を読み取り確認 | v83、未適用0008〜0013、別系統2履歴、Paid契約を確認。[記録](RAG_STAGING_PREFLIGHT_20261019.md)。復旧実施/配備前照合はStep 8〜9 |
| 3（調査完了・配布対応残） | Linux base OSと依存/モデルの利用条件を確認 | OS429/wheel102/モデル3を確認。[調査](RAG_LICENSE_REVIEW_20261019.md)。license本文同梱/native配布条件/OS CVEは配備前の残件 |
| 4（設計完了） | 一時job/intake/receipt/tombstoneの保存期間・削除順を設計 | [設計](RAG_PDF_RETENTION_DESIGN.md)。独立Planner/Code/Security確認、Medium2件修正済み。実削除は未実施 |
| 5（A/B/Cローカル完了、D残） | 保存期間に従う有限cleanupと監視を実装・試験 | [Step5-A実装結果](RAG_PDF_RETENTION_IMPLEMENTATION_REPORT.md)。nullable時刻/expiry詳細削減/集計、1865件と実local D1成功。[Bの処理済み台帳整理](RAG_PDF_PURGE_IMPLEMENTATION_REPORT.md)も実装・1888件と実local D1成功、初期無効。停止証拠保存済みjobの回復はStep6-Bで接続、account PDF phaseはStep5-Cで接続、DO/receiptは未完 |
| 6（A/Bローカル完了） | claimed後の停止不明・executor token紛失時の復旧を設計/実装 | [B接続結果](RAG_PDF_STOP_INTEGRATION_REPORT.md)：保存済み停止証拠から精算、0017にFKcascade親/証拠retention。1923件と実localD1成功。証拠前executor消失は保持。remote未反映 |
| 5-C（ローカル完了） | account PDF pending checkpoint/他phase継続/最終判定 | [結果](RAG_PDF_ACCOUNT_CLEANUP_REPORT.md)。owner専用処理、最小checkpoint、旧deleted再確認、証拠付きretry。実KV/remoteは未検証 |
| 5-D1（ローカル部品完了） | private v2期限固定/旧RPC拒否の境界 | [D1結果](RAG_DO_V2_BOUNDARY_REPORT.md)。private41件/MCP1936件、実localRPC/SQLite成功。MCP未接続・purgeなし・flag未設定 |
| 5-D2a（ローカル完了） | MCP immutable envelope保存と全caller移行 | 0018・固定CAS・全停止adapter・旧pending drain。実local RPC/DO確認、VM IOは合成。実VM停止はD2b前提の残件 |
| 5-D2b-A（ローカル完了） | 停止観測の永続化と削除前提検証 | v2のdestroy後時刻固定、実Linux再試験。物理purge/alarm分離は未実装 |
| 5-D2b-B（設計完了・未実装） | DO再実行防止の方式選定 | [設計](RAG_DO_REPLAY_FENCE_DESIGN.md)。marker保持既定、既存D1 one-shot start CASを第一候補。grace/clock/backup/alarmは削除前提として保持 |
| 5-D2b-C1（ローカル完了） | start消費metadata＋内部CASを未接続で実装 | 既存行unknown保持、許可再発行なし、同時/unknowncommit/失効/parentpurge回帰。private/HTTP/flags/配備は未接続 |
| 5-D2b-C2（次）〜C4 | gate接続→全task/clock/backup/alarm/grace→marker整理 | 各段階を独立レビュー。条件不足のまま有限purgeしない |
| 7 | 実測に基づく並列数/メモリ/時間/利用上限、異常時停止手順を校正 | shadow unitsを実請求上限としない |
| 8 | staging配備範囲/費用と試験範囲を確定 | 現在のremote承認は未受領。既存DB backup/rollback準備、Step3のlicense本文同梱/native配布条件/OS CVE残件を解消 |
| 9 | 必要migrationとprivate→public staging接続を段階反映 | flagを閉じた初期状態、各段階の独立確認。条件不足なら有効化しない |
| 10 | 実Cloudflareで合成PDFの正常変換を確認 | 認証→有限受信→一度解析→complete/精算、出力整合 |
| 11 | 実Cloudflareで通信遮断/取消/期限/alarm/destroy/残存を確認 | ローカル試験をremote隔離の証明に流用しない |
| 12 | 正式採用の非本文receipt契約とDB migrationを実装 | job/intake/document/epochs/PDF・manifest・text hashの結合 |
| 13 | receiptと文書registryを原子的に登録する | 片側失敗rollback、既存ID/別owner拒否 |
| 14 | 再送・二重採用・世代切替の契約を実装 | 同receiptは同文書/世代へ収束、登録後はregistry認可へ移行 |
| 15 | 採用APIとLibrarySyncの引き渡しを接続 | 採用直後に通常同期で別generationへ上書きしない |
| 16 | iPadに原PDF送信の別同意と受付クライアントを追加 | account/endpoint/同意epochとintakeを固定 |
| 17 | 進捗・取消・失敗時の表示を接続 | 二重送信/無条件再解析なし、未対応PDFを欠落した成功にしない |
| 18 | iPadにNDJSON受信/complete/全長/hash/PDF結合の検証を実装 | 暫定manifestは正式保存せず、破損・切断で破棄 |
| 19 | 既存structured validator/暗号化保存へ接続 | 文書ID固定、保存直前の再認可、ロックで平文を残さない |
| 20 | 端末保存とサーバー採用の片側成功・再起動から復旧する | receiptによる冪等再開/補償、半端な文書をホーム検索へ出さない |
| 21 | ホーム登録→構造索引→自動検索→引用ページまで接続試験 | PDF選択から質問/根拠表示まで一連で成功 |
| 22 | 実機・旧store/旧アプリ/旧Worker・iCloud互換を試験 | ロック/削除/アカウント切替/通信断を含む |
| 23 | 基本版の総合評価セットと基準を固定 | 抽出/索引/検索/回答/表示/遅延/費用を別採点、未使用20問を調整しない |
| 24 | 基本版を評価し失敗箇所ごとに修正 | 機能テスト数を回答精度と混同しない |
| 25 | 実semantic encoderを本文内の分割へ接続する候補を実装 | 見出し/ページ/表の構造保護＋長文再帰分割を維持 |
| 26 | 分割候補と現行fallbackを同一資料で比較 | 検索根拠の保持/欠落/遅延/費用で採否判断 |
| 27 | queryPlanの主語/複合要求/metadata範囲を評価・改善 | 書換えが必要な場合だけ追加候補、誤った対象補完を測定 |
| 28 | 現BAAIとCohere/Qwen等の候補リランカーを同一候補集合で比較 | 日本語/表/長文/recall/遅延/料金/送信先条件で採否判断 |
| 29 | 図/OCR/数式/長文PDFの対応範囲を個別評価 | 初版10MiB/20pageを勝手に拡大しない、未対応を明示 |
| 30 | 必要なOCR/図/数式対応と精密bbox表示を追加候補として検証 | 初版で必要な範囲を優先し、一括必須採用にしない |
| 31 | 友人候補の固定context比較と独立採点を完了 | APIアクセス・モデル・件数・費用条件を固定、人間oracle確認 |
| 32 | 必要回答項目/聞返し/資料と補足の境界を評価する | 条件/例外/単位/不明値/過剰拒否/説明不足を別採点 |
| 33 | 必要時に限定的な生成後validator候補を検証 | 誤拒否/見逃し/追加遅延費用を測定、修正ループを強制しない |
| 34 | 有効なprompt候補だけ統合し実検索付きで再評価 | 固定contextの成績を総合品質としない。本番v1は採用判断まで維持 |
| 35 | 最終回帰・独立レビュー・運用/rollback確認 | 削除/失効/停止/費用監視と実機結果をそろえる |
| 36 | 文書/引き継ぎ/Notionと公開候補を整える | 必要なcommit/push/merge/配備は承認範囲ごとに区別 |
| 37 | 限定公開の対象・予算・対応範囲を承認後、配備/監視 | 本番/ストア公開をstaging承認に含めない |

順序1〜24が基本版を一連で使用可能にする本体作業。25〜34は測定に応じた精度改善で、改善しない候補は採用しない。31〜33の友人による固定context作業は今から並行可だが、34の統合評価は本体接続後に行う。remote承認待ちでも12〜20のローカル実装は進められる。3〜7と実基盤試験は相互に測定結果を反映する。

友人への招待は2026-10-18送信済み、直近確認では本人承諾待ち。承諾後にproject Member権限/本人キー/PC設定/評価費用を確認。招待を送っただけでAPI使用可能とは扱わない。

将来別フェーズ: RAGをツールとして呼び、複数回検索や操作を判断するAIエージェント。RAG本体の検索/引用/認可/期限/費用契約を安定させた後に具体化する。

## 現行ロードマップ（2026-10-18）

ユーザーの設計計画依頼に基づく。現在地の正本は最新handoffと実コード。以下がこれからの優先順で、後半の2026-10-17記録は経緯として保持する。今回は計画のみ、公開/配備/有料評価/設定変更を承認済みとはしない。

目的: 許可したホームのPDFを質問に応じて探し、該当ページを根拠に、資料の内容と理解の補足を区別して分かりやすく答える。

2026-10-18 現在地更新: 内部orchestrator/受付行数制限に続き、停止再試行reaperと集計を実装。最大3回のremote cancelと未claim安全精算まで。claimedの停止証拠付き自動回収、retention、公開schedulerは未実装。全サーバー1,825件成功。実Linux環境は用意/指定の回答待ち。次の独立作業は[新Notebook採用のmetadata/registry移行契約](RAG_PDF_ADOPTION_DESIGN.md)と合成状態試験。本文staging/転送方式は未確定、採用設計を実装済みとは扱わない。停止詳細: [復旧設計](RAG_PDF_RECOVERY.md)。

### 現在できている部品

- Doclingの構造抽出、本文の構造維持/再帰分割、表保護、metadata付き索引入力、prepared packageのiPad取込。
- 本人/許可範囲に限定した意味＋キーワード検索、順位統合、現行BAAI再順位付け、ページ出典、OpenAIの資料確認/解説の回答方針。
- 原PDFの有限reader、別同意epoch、登録済み文書認可、新規intake世代/UUID/原PDF digest/期限/取消とbytes検証。直近サーバー全体1,775 test成功は実装回帰の結果で、実資料の回答品質を示さない。
- 未完成: 原PDF→解析→新Notebook→自動索引の一連接続。実encoderによる自動意味分割、図/スキャン/数式解釈、実基盤/実機検証も別の残件。

### 先に固定する評価基準

実装着手時に、利用を許可された合成PDF・質問・期待する根拠・制限値を固定する。評価は最後まで延期せず各Stepで繰り返す。Step 5は初回総合試験、改善候補の採用後にも最終総合試験を行う。開発テストと実資料の精度を別の成績にする。

### A. まずPDF自動解析を一連で使える状態へ

| 順序 | 利用者にとっての意味 | 実装するもの | 完了の確認 |
| --- | --- | --- | --- |
| 1. 利用枠と重複防止 | 二重タップで同じ解析が何回も走らず、処理集中を抑える | 受信前の受付数/利用枠/並列メモリ予約、期限付きjob台帳、単一勝者の処理claim、idempotency、予約/確定/解放の区別。実測前に架空の費用を確定しない | 同時送信・再送・途中停止で二重実行/二重計上なし。上限時は本文受信前に止まる |
| 2. 取消・削除・後片付け | キャンセル/ロック/削除/同意撤回で処理と結果採用を止める | 受付→受信→実行→完了/失敗/取消の状態遷移、失効とprivate cancel連携、lease期限、cleanup retry、再起動回復、最小tombstone/保存期間整理 | 受信/解析/返却の各途中で失効を注入。停止不明やcleanup失敗を成功にしない。停止済みを未確認のまま返金確定しない |
| 3. Doclingへの実接続 | PDFから本文・表・ページ情報を取り出す | Linux依存/モデル同梱の再現build、private Worker/Container契約、admission→本文前認可→有限reader→bytes digest→再認可→一度だけdispatch、strict結果検証。原PDF非永続、外部通信制限 | 合成PDFで実parserまで接続し、容量/20page/期限/取消/破棄/不正結果を確認。mock成功と実Linux/Cloudflare成功を分ける |
| 4. iPadと索引への接続 | PDFを選んで待てばホーム資料になり、その資料に質問できる | 原PDF別同意画面、受付/進捗/取消、結果package検証、intake世代と新Notebookの採用対応、暗号化保存→既存structured索引へ接続、途中失敗時の整合/旧Worker互換 | PDF選択→解析→ホーム表示→自動検索→引用ページまで一連確認。失効後の結果保存や半端な登録を防ぐ |
| 5. 基本版の総合評価 | どのPDFで何ができるか確認できる | 合成/利用許可された実PDF、複数資料、矛盾/情報不足、offline/再起動/旧store/iCloudの試験。抽出/索引/検索/回答/表示を別に採点 | 機能テストだけでなく必要な根拠の検索漏れ・誤回答・過剰拒否・待ち時間・費用を記録。対応範囲を明記して基本版の採否を判断 |

Step 1〜2は状態遷移を一緒に設計してから分割実装する。期限が切れただけで旧jobの停止を確認せず枠を解放せず、開始有無が不明な通信障害でも無条件再送しない。停止スイッチ/監視/保存期間/復旧の設計も最初から含める。

Step 3はまずLinux/隔離の基盤検証、その後に一連のprivate接続の順。Linux準備はStep 1〜2と並行可能。ただし必要な導入/配備・実送信/追加費用は個別の承認範囲で扱う。初版は本文と表の取れるPDFを対象にし、スキャン/図/数式や不完全な資料を黙って欠落させない。既存online上限10MiB/20pageは初期契約であり、性能保証ではない。

### B. 基本版を測ってから精度を改善

| 順序 | 利用者にとっての意味 | 実装/実験するもの | 完了の確認 |
| --- | --- | --- | --- |
| 6. 読み取り・分割改善 | 同じ話の途中で文章を切らず、表や例外を壊さない | 本文要素内だけに実semantic encoderを接続し、長すぎる部分へ再帰分割。見出し/ページ/表の構造保護を維持。OCR/図/数式はそれぞれ独立した追加対応として評価 | 現在のvectorsなしfallbackと同じ資料で比較。欠落/境界/原文範囲/検索品質と処理時間・費用を測り、改善候補だけ採用 |
| 7. 検索・順位の改善 | 多数のホームPDFから質問に必要なページを探す | 既存ルール式queryPlanを基準に主語補完/複合要求/metadata範囲を評価。必要時のみ追加rewrite候補。現BAAIと候補リランカーを同じ候補集合で比較、対象coverageとTopKを調整 | 検索recall/最終根拠保持/誤rewrite/owner境界/遅延/費用を測る。一度にモデルと分割とpromptを変えない |
| 8. 回答の漏れ・分かりやすさ | 聞いたことに過不足なく答え、資料外の補足を区別する | 質問の必要項目と根拠の対応、条件/例外/単位/不明値の保持、source_only/explain、限定的な生成後validatorを評価環境で試す。友人候補を固定contextで比較してから統合 | 未知値の補完、説明不足、過剰拒否、資料と補足の混同、出典不一致を別採点。validatorの誤拒否/見逃し/追加費用・待ち時間も測り、候補不採用を許容 |
| 9. 限定公開と運用 | 安定した範囲で使い始め、問題を見つけて止められる | migration順/旧版互換、flag停止、非本文監視、利用上限、削除/障害回復/rollback手順、限定ユーザー試験 | 独立reviewと実機/実基盤結果を揃え、公開範囲・予算・停止判断を人間が承認してから配備 |

Step 4は結果採用の安全な対応付けを独立した実装単位にする。同じ結果の二重採用、保存途中失敗、取消/ロック/account・endpoint切替後の遅い結果を防ぐ。既存Notebookの原PDF再解析には原本再選択が必要。精密bboxジャンプはページ出典とは別の追加対応。

Step 8でvalidatorを採用する場合は、検証前の回答を先にstreamせず、追加呼数/費用/期限/取消/再認可を制限する。自動修正ループは既定にしない。

Step 6〜8は改善提案であり、候補を必ず本番採用する約束ではない。重いOCRや複数モデル検証を全質問/PDFへ強制しない。基本版の限定公開を先行する場合もStep 9の承認・停止/削除・品質基準は省略しない。

### Step1〜2の初回実装記録（2026-10-18）

0012/pdf-jobs.jsに未接続admission/job状態機械を実装。reserve一意・server policy必須のactive/memory/day件数/units制限、受信claimとdispatch各一勝者、失効/期限の停止要求・停止確認精算を追加。実装詳細/検証は段階設計とhandoff参照。reader/Doclingの実停止、reaper・停止不明復旧、intake行数/rate上限、retention、実環境検証が残るためStep1〜2全体の完了とはしない。

### 評価・分担・計画の完了条件

- 各Stepで対象テスト→関連回帰→独立review。実装済み/未接続/実環境未検証を記録する。
- 開発30問と未使用20問を分離し、未使用20問を調整に使わない。新有料runはモデル/入力/版/件数/予算を固定し承認範囲で実施する。単なるテスト件数を正答率にしない。
- 友人は現在の固定context/候補専用領域で回答品質案を並行作成できる。本体は接続/認可/処理・検索を担当。retrievalのcontextが変わる統合時は同じ基準で再評価し、固定context評価の好成績を一連品質の証明にしない。
- 本番prompt出力v1を維持。A/C候補不採用の記録を保持。質問要求分解/生成後validatorは未実装の本番機能で、評価土台と混同しない。
- RAGを使うAIエージェントの自律的な複数回検索/操作は別フェーズ。まず検索・引用・権限・期限・費用上限の安定したツール契約を完成させる。工程1〜5をこの能力の完成と呼ばない。
- 日数は実Linux/実D1/実機の未確認依存があるため現時点で確約せず、各Stepの完了基準で進める。

## 以前の計画・実装記録（履歴）

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

2026-10-18: 内部orchestrator/strict manifest/reader cleanup観測/bounded intake行数制限まで継続。全体1812成功、実offline Docling合成2page/POST1回/7.642秒/停止・一時領域削除を確認（VMlifecycle mock）。review指摘修正済み。実Linux/VM検証はDocker/Podman不在で環境選択待ち。詳細RAG_PDF_ORCHESTRATION_REPORT.md/RESULTS.json。

## 2026-10-18 実Linux・公開HTTP接続（最新）

実Linux amd64コンテナで合成2ページを解析（22.908秒）、通信遮断・UID10001・非書込コード/モデル・取消・期限切れ・SIGTERM・job削除を確認。認証済みローカルworkerd→private RPC→同Linux Docling→最終complete/精算も21.045秒で成功した。Cloudflareへの配備・remote migration・公開URL有効化は未実施で、ローカル成功をremote完了とは扱わない。

公開HTTP handlerは認証後に同意/intake/process/cancelを処理する。受信前認可・予約、転送中の再認可、停止精算後のcompleteを維持。早すぎるResponse返却によるworkerdの入力破棄、isolated Pythonの兄弟import、WranglerのCASE分割を実環境で修正。受付/cleanup/private実行flagsはfalse。本番private bindingなし。staging設定とdry-runを準備済み。

検証: サーバー全1,851件、processor61件、provision6件、HTTP/app/process42件成功。Python102依存のauditは既知脆弱性0・skip0（OS/モデルライセンスの保証ではない）。独立Code/Securityレビューの未解決所見なし。回答品質の有料評価・実資料・未使用20問は使っていない。

詳細・制約・ロールバック: [実Linuxと公開接続の検証](RAG_LINUX_PUBLIC_CONNECTION_REPORT.md)。次はstagingの既存配備/DB状態と利用条件を確認し、remote配備の承認範囲を確定してから段階適用・疎通する。iPad正式採用、claimed停止不明の復旧、retentionは残る。


2026-10-20 Step5-D2a: MCP側の不変v2 envelopeと全停止callerを接続。0018追加型、既存metadata/会計/停止証拠の保持条件は維持。新12回帰、実local D1(18migration)/service RPC/SQLite DO＋合成VM IOで解析→両停止証拠→精算を確認。実Cloudflare Container停止・D2b物理削除・flags有効化・配備なし。[結果](RAG_PDF_RPC_V2_INTEGRATION_REPORT.md)。
