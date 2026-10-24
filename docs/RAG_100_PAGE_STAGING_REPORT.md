# 合成100ページPDFのstaging検証（2026-10-09）

作業先 `.worktrees/rag-wip`、ブランチ `codex/rag-wip`。ユーザー承認に基づきstagingのみ更新し、合成資料をCloudflare Workers AI／Geminiへ送信した。本番は変更していない。Highの計画・安全確認・ロールバック検討と独立レビューを実施した。

## 結果と限界

修正後の最終実環境試験は **65/65確認成功**。Worker全テスト **800/800成功**、対象回帰テスト **15/15成功**。100ページ・100chunkを5ページずつ20回で登録した。登録は **125.809秒**、最後の登録から確認APIでreadyを観測するまで **70.669秒**。直前の別試行では134.340秒＋94.821秒だった。10秒間隔のポーリングで観測した時間であり、正確な反映瞬間ではない。readyは全ID取得と資料単位の検索成功を意味し、すべてのchunkのANN検索や全質問の正解を保証しない。

同じPDF・sourceHashの20batch再送信は再Embedding **0件**、100ページすべてskip。無認証／偽Bearerは401、RAG保存同意なしは403、50ページ時点ではupload_incomplete、不正batchは400。bodyのaccount情報を偽装しても所有者はBearerのcanonical userから決定された。別所有者のsource確認はmissing。folder／notebook／current pageの制約、空folderの通常AIへのfallback、source削除、account RAG削除を確認した。

| 質問ケース | 検索状態 | 出典ページ | 回答完了まで |
| --- | --- | --- | --- |
| library | grounded | 86, 1, 87 | 5.568秒 |
| folder-ocr | grounded | 5 | 2.370秒 |
| notebook-ocr | grounded | 7, 10 | 2.207秒 |
| current-page | grounded | 11 | 4.224秒 |
| wrong-folder | fallback | なし | 5.364秒 |
| other-owner | grounded | 1 | 2.439秒 |

5つの資料内質問で期待ページが含まれ、空folderを含む全6問で回答が返った。回答内容を合成資料と照合し、光合成・夜の植物の呼吸・100℃未満での蒸発・地震波・別所有者の架空植物の色は一致した。ただし光合成の回答には根の吸収を説明する86／87ページも含まれ、出典の適合性を改善する必要がある。これは6問のsmoke testであり「検索精度100%」ではない。

反映直後の私有ランタイムで、同じ光合成の言い換え質問が通常回答へfallbackした。一方、後続の公開Workerでは期待ページを取得した。原因の切り分けは未完了。登録可能／検索可能表示と、質問ごとの検索品質は分けて評価する。

## 発見した問題と修正

初回は100ページ登録後のreadinessが503。実bindingでgetByIdsを10／20／50／100 IDで再現し、20までは成功、50／100は40007（max id count is 20）になった。`src/rag/storage.js`へ20件ずつの共通取得処理を追加し、readiness・hashによるEmbedding再利用・folder移動へ適用した。認可条件と移動／編集のlease検証は維持した。

初回試行は30/33で止まり、helperの再読込中に後片付け確認も一度失敗した。追加復旧でD1 chunk 0／Vectorize 0を確認した。第2試行は57/59で、検証クライアントに通常AI送信同意 `google-v2` を付け忘れ、正しく403になった。アプリは既に同意ヘッダーを送信している。検証側だけを修正し、最終試行は65/65。失敗履歴は[構造化結果](RAG_100_PAGE_STAGING_RESULTS.json)に残した。

## 実測と費用

実Workers AIへの私有ランタイムからの2質問計測では、BGE-M3は355／179ms（1024次元）、reranker-baseは1回520msで成功。検索全体は1.369秒（fallback）／2.800秒（grounded）。ネットワークやKVの検証処理を含み、公開Workerのmodel単体計測ではない。公開Geminiチャット6問の完了時間は2.207〜5.568秒、中央値3.332秒。ストリームを最後まで消費した時間であり、先頭文字までの時間ではない。

100ページ分のEmbedding入力46,641文字、chunkerによる推定25,737 token。BGE tokenizerの実測や請求明細ではない。[Workers AI公式単価](https://developers.cloudflare.com/workers-ai/platform/pricing/)のBGE-M3 $0.012／100万入力tokenで約 **$0.000308844／100ページ**（無料枠控除前の推定）。3試行の100ページ部分は約$0.000926532。ほかに別所有者の2chunk、質問Embedding、Reranking、D1、Workers、Geminiの利用がある。

100vector×1024次元＝102,400保存次元。[Vectorize公式単価](https://developers.cloudflare.com/vectorize/platform/pricing/)で仮に1か月保持した保存料金は約$0.0000512（包含枠控除前の計算）。今回は削除済みで、この月額を今回の請求額として扱わない。検索料金も別。アカウント全体の無料枠・実token・Gemini usageMetadata／請求額は確認できていないため、総額や「無料」とは断定しない。

## 配信状態・削除・安全確認

最終配信は `9f03da7e-8c3b-4d81-9e7e-bce0e0853e87`、100%配信、`RAG_ENABLED=false`／`AI_PROVIDER_APPROVED=false`。一時 `GEMINI_API_KEY` は削除済みで既存3secretは維持した。生成したセッションと検証用KV記録も削除した。3試行の両所有者についてD1 source／page／chunkは0、FTS全体0、専用Vectorize全体0を読み取りで確認した。削除との競合を防ぐaccount hashの削除バリア6件は保持し、本文やタイトルを含まない。

- accountKeyをWorkerで生成し、Vectorizeに所有者filter、D1で所有者／scopeを再確認する経路を使用。
- source削除は公開API、account削除のRAG部分は本番実装関数を固定合成所有者に対して実行。認証情報やアプリの退会画面を含むaccount全削除のE2E試験ではない。
- 本文・prompt・Embedding値を運用ログへ追加していない。検証中の合成回答は私有一時ファイルにのみ保存し、報告には集計値を掲載。
- 実紙PDF （ファイル名は非公開） やユーザーの学習内容を外部AIへ送信していない。
- 今回の修正・配信対象について独立セキュリティレビューと修正後の再レビューを実施し、残る指摘なし。

## ファイル・運用変更

今回のコード修正は `mcp-server/src/rag/storage.js`、`src/rag/readiness.js`、`src/rag-readiness.test.js`。文書は本報告と結果JSONを新規追加し、`HYBRID_RAG.md`、`RAG_REGISTRATION_STATUS_REPORT.md`、`STAGING_SETUP.md`、新規release記録を更新した。既存の未コミットRAG／iOS変更を破棄していない。

新しいmigration／bindingは追加していない。stagingは0006／0007適用済みの既存D1・Workers AI・専用Vectorize・RAG rate limitを利用した。恒久flagの初期値はfalse。新しく恒久保存したsecretはない。Vectorize作成・metadata indexコマンドとbindingは [HYBRID_RAG](HYBRID_RAG.md)を参照。評価時のみAPIキーと承認flagを設定し、終了時に戻した。

既存のRAG説明を含む `legal.js` をstagingスナップショットに含めた。資料のCloudflare保存、Embedding／Reranking、抜粋のGoogle送信、削除再試行とバリア保持の記載がある。今回さらに送信先や保存種類を増やしていない。本番のプライバシー申告や契約・年齢適合性の承認を完了した扱いにはしない。

ロールバックはまずRAGをfalseへ戻し、削除処理とschemaを維持する。これを実施・配信確認済み。更新前の版は `497cc667-88ea-423a-97f7-06b87aee0070` だが、今回その版へコードを戻す操作は行っていない。stagingはRAG開発スナップショットであり、認証リリース候補のクリーンなcommit検証を代替しない。

## 本番有効化前に残る作業

- 出典の余分なページを減らし、反映直後の質問ごとの取得安定性を独立の評価セットで測る。
- 合成PDFは80ページのtext layer＋20ページの合成scanを以前OCRして得たテキストを使用。今回はOCR再実行や実紙認識品質の検証ではない。短い各ページから1chunkだけ生成した100chunk試験であり、複数chunk／pageの厚い100ページ資料も検証する。
- 1,000chunk確認時は最大50回のID取得にD1／queryを加えるため、プランのsubrequest上限とiOSの20秒timeoutを評価し、必要なら確認を分割する。
- 実iPadは2台ともoffline。接続後、stagingで登録表示・反映待ち・取消・出典タップを操作して確認する。前工程のシミュレーター関連38件成功は今回再実行していない。iOS全suiteも今回未実施。
- プライバシー／外部AI契約・同意・プラン別上限・費用監視、production migration／binding／secret設定を個別に確認してから有効化する。

Project資料: [設計] HYBRID_RAG.mdの複製、[リリース] 00_残タスク表.md、release記録とlegal-pages-source.js.txtの差し替えが必要。Desktopの複製とProjectへのアップロードは変更していない。

後続のローカル修正（まだstaging未配信）: [出典選択・検索障害分離・代表ページprobe](RAG_CITATION_STABILITY_FIX_REPORT.md)。従来の実測値はこの報告の時点のコードに対する結果として保持する。
