# 日本語RAG品質評価

現在の回答モデルはOpenAIです。以下のGeminiへの言及は過去の評価記録です。退役したGemini手順やキー設定を再利用せず、OpenAI用runnerの節と引き継ぎを確認してください。有料評価は明示的な承認時だけ実行します。

個人情報を含まない合成100ページPDFをPDFKit/Visionで抽出し、Workerの索引・検索コードで評価します。Workers AIは実API、DBはローカルSQLite FTS5、Vector検索はローカル厳密cosineです。実Vectorize/Worker bindingの評価とは区別してください。

必要環境: Node 24（node:sqlite）、Python 3、macOS Swift/PDFKit/Vision。追加パッケージは不要です。

```sh
mkdir -p /private/tmp/studiquo-rag-quality-run
python3 mcp-server/scripts/rag-quality/build-fixture.py /private/tmp/studiquo-rag-quality-run
swift mcp-server/scripts/rag-quality/pdf-ocr.swift /private/tmp/studiquo-rag-quality-run
python3 mcp-server/scripts/rag-quality/ocr-metrics.py /private/tmp/studiquo-rag-quality-run
```

Macでは、`scripts/rag-eval`を入口にすると、専用トークンをキーチェーンから読んで安全に実行できます(値を毎回入力しません)。有料の呼び出しの前に確認を求めます。

```sh
scripts/rag-eval store                                   # 最初に1回: アカウントIDとトークンを保存
scripts/rag-eval check                                   # トークンが有効か(利用量は使わない)
scripts/rag-eval real-material <manifest.json> <出力.json>
scripts/rag-eval quality /private/tmp/studiquo-rag-quality-run
scripts/rag-eval forget                                  # 保存したトークンを消す
```

実API呼出しは少額の使用量を発生させます。`CLOUDFLARE_ACCOUNT_ID`を対象アカウントへ設定し、Workers AIだけの専用トークンを`CLOUDFLARE_API_TOKEN`に設定します(発行・期限・受け渡し・削除の決まりは`docs/RUNBOOK.md`の付録A-5。事前に`node mcp-server/scripts/rag-quality/check-cf-token.ts`で有効性と期限を確認できます)。Wrangler OAuthは権限が広いため既定では使えず、手元の開発機で意図して使うときだけ`STUDIQUO_ALLOW_WRANGLER_OAUTH=true`を付けます。secret値はファイル・コマンド引数・結果に書き込まないでください。OAuth保存場所が異なる場合は`STUDIQUO_CF_AUTH_FILE`で認証ファイルのパスを指定できます。

```sh
STUDIQUO_RAG_QUALITY_REMOTE=true node mcp-server/scripts/rag-quality/evaluate.ts /private/tmp/studiquo-rag-quality-run
STUDIQUO_RAG_QUALITY_REMOTE=true STUDIQUO_RAG_REWRITE_CONTROLS=true node mcp-server/scripts/rag-quality/evaluate.ts /private/tmp/studiquo-rag-quality-run
```

最初の実行は60問、2番目は曖昧質問の対照10問を評価し、別のv2 JSONへ記録します（過去v1の結果を上書きしません）。各実行は100ページの索引を独立して作ります。結果には本文・質問・Embeddingベクトル・認証値を含めません。sourceHashによる再送時のEmbedding呼出し増加がないことも確認します。

goldenページは実行前に固定したfixture.jsonを参照します。合成資料の共通説明が多い点や、小さなサンプルの限界を考慮してください。初回検証の結果はdocs/RAG_SEARCH_QUALITY_EVALUATION.mdを参照してください。低品質scan・手書き・複雑なレイアウト・実iPadでの評価は別工程です。

追加fixtureとしてholdout-fixture.json（40問）とvalidation-fixture.json（20問）を評価ディレクトリへコピーし、STUDIQUO_RAG_QUALITY_SET=holdoutまたはvalidationで選択できます。holdoutは初回未使用の検証用でしたが、その結果から1文字主題の修正を行ったため、将来の未使用holdoutとして再利用しないでください。validationには同じ話題で本文に答えのない難negativeを含めます。

具体情報の根拠判定だけをオフラインで再評価する場合は、生成・OCR済みの合成資料のextracted-pages.jsonを指定します。保存済みv2検索結果のページを固定して、新しい判定を適用します。実AIの再呼出し、検索順位やGemini回答の再評価は行いません。

```sh
node mcp-server/scripts/rag-quality/answerability-replay.ts /private/tmp/studiquo-rag-quality-run/extracted-pages.json /private/tmp/answerability-results.json
```

結果と限界はdocs/RAG_ANSWERABILITY_IMPLEMENTATION_REPORT.mdを参照してください。

Geminiの最終回答の評価はfinal-answer-fixture.jsonの合成24問を使い、本番handleAIの回答処理を再利用します。検索側はfixtureで、検索精度の再測定ではありません。Git除外済みのmcp-server/.dev.varsにGEMINI_API_KEYをローカル設定して実行します。

```sh
STUDIQUO_RAG_ANSWER_REMOTE=true node mcp-server/scripts/rag-quality/final-answer-evaluate.ts output/rag-final-answer
```

API使用量が発生します。stdoutには進捗だけを出し、metrics.jsonに予備チェックと使用量、synthetic-answers.jsonに合成回答を保存します。自動チェックだけでは回答の意味的な正しさを判定しないため、手動レビューが必要です。実測状態と詳細はdocs/RAG_FINAL_ANSWER_EVALUATION_REPORT.mdを参照してください。

## 実資料の検索評価

公開教材または利用可能な指定資料を評価する場合は、`extract-material-pdf.ts` と `real-material-evaluate.ts` を使用します。抽出driverはアプリのRAGDocumentTextExtractionServiceとSwift CLIを一緒にコンパイルし、同じ本文統合方針を利用します。合成fixtureと実資料の結果を混ぜません。本文・質問・anchorを含む入力はGit対象外の私有ディレクトリに保管してください。

```sh
mkdir -m 700 /private/tmp/real-material-evaluation
node mcp-server/scripts/rag-quality/extract-material-pdf.ts /path/to/authorized.pdf /private/tmp/real-material-evaluation/pages.json
STUDIQUO_RAG_REAL_MATERIAL_REMOTE=true node mcp-server/scripts/rag-quality/real-material-evaluate.ts /private/tmp/real-material-evaluation/manifest.json /private/tmp/real-material-evaluation/metrics.json
```

抽出出力は新規のみ、作成時0600。既存ファイル・symlinkを上書きしません。macOS PDFKit/Visionで全ページをOCR確認し、文字層を保持したまま高信頼な本文を補完します。スキャン本文の低信頼認識は確認対象として区別し、数式・孤立した断片を補正式として追加しません。PDF 100MiB・1000ページまで。needsReviewは数式、低信頼、未抽出等の保守的な確認案内であり、完全な誤読検出ではありません。画像解像度やOSによって認識が変わるため、macOSの評価を実iPadの認識精度と同一視しません。

manifestには `sources`（sourceId/title/kind/sourceHash/totalPages/pagesFile、任意folderId/pagesHash）と `questions`（id/query/expected/expectedEvidence、任意kind/previousQuestion/scope）を指定します。expectedはsupportedまたはno_evidence。expectedEvidenceは必要な根拠のgroup配列で、各groupは代替候補 `{sourceId,pageNumber,anchor}` の配列です。ページは物理PDFの1始まりです。ページファイルはmanifestと同じディレクトリの配下へ置きます。正解を実行前に固定し、anchorは本文に実在する短い記述にしてください。

account IDはローカルのCLOUDFLARE_ACCOUNT_ID、資格情報は専用のCLOUDFLARE_API_TOKEN(例外としてSTUDIQUO_ALLOW_WRANGLER_OAUTH=true時のWrangler OAuth)から利用します。結果には質問・本文・題名・vector・認証値を保存しません。STUDIQUO_RAG_REAL_MATERIAL_PROGRESS=trueなら件数のみ進捗を表示します。最大500API calls。

pageRecallとevidenceRecallを区別し、qualityEligible=falseのAPI障害・不正Embedding・deadline付近は品質の分母から除外します。Reranker障害時の既存順位fallbackは別途報告します。D1/Vectorizeはローカル代替で、実binding・Gemini最終回答・実機の精度とは区別します。

初回の実資料結果・限界・固定hashは `docs/RAG_REAL_MATERIAL_EVALUATION_REPORT.md`、非本文メトリクスは `docs/RAG_REAL_MATERIAL_RESULTS.json` を参照してください。

## 段落ID評価の手動再開

`paragraph-resume.ts`は同一条件hashの状態を読み、quota待機中はキー読み込み・API送信を行わず、形式成功済み問題を除いて再開します。形式成功は意味品質の合格を示しません。自動予約はありません。

```sh
STUDIQUO_RAG_PROPOSAL_REMOTE=true STUDIQUO_RAG_KEY_FILE=/path/to/existing/.dev.vars node mcp-server/scripts/rag-quality/paragraph-resume.ts /private/tmp/studiquo-paragraph-resume-state.json /private/tmp/studiquo-paragraph-resume-result.json
```

第1引数は状態、第2引数は詳細結果。同じ状態の同時起動は拒否します。強制終了で残ったlockは稼働プロセスがないことを確認して手動で解消してください。中断時の詳細usageは復元できず、API応答と保存の間の強制終了では再送が起こりえます。初期状態・待機由来・検証結果は `docs/RAG_PARAGRAPH_RESUME_REPORT.md` を参照してください。

第3引数の固定profileは`coverage`（省略時、従来4問）または`multiparagraph`（新しい4問）です。任意fixture pathは受け付けません。profileごとに別hash・別stateを用意し、旧実験の成功行を流用しません。新実験にも既知のquota待機期限と由来を引き継ぎ、上限の待機を迂回しないようにします。

修正指示の比較には`multiparagraph-complete`を使用します。同じ4問に、質問の各要素を根拠段落で網羅する指示を渡します。既定の旧指示は不変で、promptを含むhashが異なるため、修正後の別stateを指定してください。3段落の上限・5秒制限・全文保持は変わりません。

結果の`requiredCoverageStatus`は`complete`／`incomplete`／`not_evaluated`です。独立した暫定ラベルの必須情報を、全文とwitnessの双方が覆えたかを表し、意味的な完全性や本番利用の許可ではありません。モデルによるabstainやAPI障害は`not_evaluated`です。

```sh
STUDIQUO_RAG_PROPOSAL_REMOTE=true STUDIQUO_RAG_KEY_FILE=/path/to/existing/.dev.vars node mcp-server/scripts/rag-quality/paragraph-resume.ts /private/tmp/studiquo-multiparagraph-resume-state.json /private/tmp/multiparagraph-live.json multiparagraph
```

### 根拠段落の保持の診断

`paragraph-witness-evaluate.ts`はAPIを使わず、全文の必須情報保持と、選択段落による正解原文範囲の完全被覆を分けます。先頭段落ルールとラベルを読むoracleを比べる診断で、モデル精度・意味的関連性の実測ではありません。ラベル未付与の段落を無関係とは断定しません。

```sh
node mcp-server/scripts/rag-quality/paragraph-witness-evaluate.ts /private/tmp/paragraph-witness-controls.json
```

live評価のreport version2にもwitnessCoverageが加わります。fallbackはnull、旧結果は遡って評価できない場合は未計測です。`docs/RAG_PARAGRAPH_WITNESS_REPORT.md`に結果と段落分割の評価限界を記載しています。

### 複数段落の合成stress資料

`multiparagraph-fixture.ts`は独立した4ケース・9参照・35段落をexportします。元fixtureとresume状態には混ぜません。固定ルールとラベルを読むoracleの診断のみを行い、キー・APIは使いません。

```sh
node mcp-server/scripts/rag-quality/multiparagraph-fixture.ts /private/tmp/multiparagraph-controls.json
```

条件・否定・数式・別資料の例外を、実契約の最大3段落/参照で被覆できることを検証しています。stress資料であり、blind holdout・実教材・モデル精度ではありません。結果とラベルreviewは `docs/RAG_MULTIPARAGRAPH_REPORT.md`を参照してください。

### 時間切れの診断

`paragraph-timeout-diagnose.ts`はhidden-conditionと前後の合成対照を最大3回測定します。20秒は診断だけで、既存5秒評価とresume状態は変えません。31秒間隔、retryなし、認証・429・5xxで停止。HTTPヘッダー到着と応答処理完了を分けますが、通信とGoogle側処理の個別原因は確定できません。

```sh
STUDIQUO_RAG_PROPOSAL_REMOTE=true STUDIQUO_RAG_KEY_FILE=/path/to/existing/.dev.vars node mcp-server/scripts/rag-quality/paragraph-timeout-diagnose.ts /private/tmp/paragraph-timeout-diagnostic.json
```

キー・本文・prompt・自由エラー文は出力しません。診断結果は `docs/RAG_TIMEOUT_DIAGNOSTIC_REPORT.md` を参照してください。

## 選択資料からの最終回答（合成2問）

`complete-final-answer.ts`はcomplete方針の保存済み状態・選択結果を検証し、数式と複数資料の例外ケースの全文を直接Geminiへ渡します。実grounded回答policyを利用しますが、公開CHAT_SYSTEM・Cloudflare検索・iPadを通す評価ではありません。最大2回、20秒、31秒間隔、再試行なし。正解ラベル非送信、構造化出典はcanonical参照由来です。chunkIdは評価専用です。

専用一時ディレクトリを0700で用意し、本文を含まないmetricsと合成回答のprivateファイルを別々に指定してください。どちらも0600で保存されます。本文をリポジトリへコピーしないでください。regexは予備判定に限り、元資料との手動照合が必要です。

```sh
STUDIQUO_RAG_ANSWER_REMOTE=true STUDIQUO_RAG_KEY_FILE=/path/to/existing/.dev.vars node mcp-server/scripts/rag-quality/complete-final-answer.ts /private/tmp/studiquo-multi-complete-state.json /private/tmp/private-answer-pilot/metrics.json /private/tmp/private-answer-pilot/answers.json
```

## 新しい問題への適用確認

固定profile `transfer-complete`は新規合成2問（オームの法則の条件・不足値、疑似OCRの未確定指数と不審な命令）です。既存の調整ケースと別ですが、blind holdout・実OCRとは呼びません。最初の実送信前に原文・ラベル・採点基準を固定しています。

```sh
STUDIQUO_RAG_PROPOSAL_REMOTE=true STUDIQUO_RAG_KEY_FILE=/path/to/existing/.dev.vars node mcp-server/scripts/rag-quality/paragraph-resume.ts /private/tmp/private-transfer/state.json /private/tmp/private-transfer/selection.json transfer-complete
```

新stateは`newResumeState(transferFixture,{witnessPolicy:'complete'})`で作成し、同じGeminiプロジェクトの既知quota期限・由来を引き継ぎます。専用ディレクトリ0700を使用します。選択結果はfixture identityを含むため別profileの結果を流用できません。今回保存状態の待機目安は2026-10-12 08:59:59 JST以降です。解除を保証せず、再開前に同プロジェクトの最新quota状態も確認してください。別profileで待機を迂回しないでください。

選択2問が完全なら、最後の選択応答から31秒以上空けて次を実行します。

```sh
STUDIQUO_RAG_ANSWER_REMOTE=true STUDIQUO_RAG_KEY_FILE=/path/to/existing/.dev.vars node mcp-server/scripts/rag-quality/transfer-final-answer.ts /private/tmp/private-transfer/state.json /private/tmp/private-transfer/selection.json /private/tmp/private-transfer/answer-metrics.json /private/tmp/private-transfer/answers.json
```

quota待機中・不完全選択はキー読込前に停止します。最終回答は最大2回・20秒・31秒間隔・retryなし、auth/429/5xxで停止。metadataはavailabilityのみで、品質は`not_evaluated`／manual pendingです。原文と回答を手動照合して別記録にします。回答保存後の同じコマンドの再実行はAPIを再送しうるため、成功済み回答を確認してから行ってください。quotaが回答段階で返った場合も他の評価を含め追加送信を停止し、返された待機目安を保持してください。
