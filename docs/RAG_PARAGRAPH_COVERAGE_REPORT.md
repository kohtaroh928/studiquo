# 段落ID方式の条件・数式評価と利用制限の特定（2026-10-10）

未評価の4問を実モデルへ進めようとしたが、最初の1問でHTTP429となった。エラーの安全な解析により、**当該要求が無料の日次20回枠に抵触している**ことを確認した。APIは再試行の目安68,882秒（約19時間8分）を返した。再試行はせず、残り3問は未送信。新しい実モデル品質結果は得られていない。

## 今回の変更

- `selection-proposal-gemini.mjs`: 非2xxの本文を16KiBまでメモリで解析し、既存safeErrorの既知status/reason、quota分類・数値、retry秒のみを保存する。message/project/自由本文は保存しない。HTTP statusを先に通知するため、本文解析が失敗・停止しても429/5xxで中断できる。
- `paragraph-proposal-live.mjs`: 評価用の待機間隔を追加（0〜60秒、実行時31秒）。timeout後の遅い処理が保存観測を変えないようmetricsをコピーする。CLIの対象を未評価4問に変更。
- `rag-paragraph-proposal.test.js`: pacing、quota情報の非漏洩、不正/超過エラー本文でも停止する回帰4件、形式が正しくても必要情報が抜ける4ケースの回帰を追加。
- 新規本報告と `RAG_PARAGRAPH_COVERAGE_RESULTS.json`。`HYBRID_RAG.md`へ現状を追記。

公開Worker/iOS/検索処理/DB/Vectorize/flags/secret/migration/bindingは変更していない。外部AI・秘密情報を扱うため、fullの安全確認、Planner/Code Reviewer/Security Reviewerによる独立レビューを実施した。作業先 `.worktrees/rag-wip`。

## 予定と実際

| 合成問題 | 確認したい内容 | 実モデル結果 |
| --- | --- | --- |
| split-materials | 材料・生成物が別ページに分散 | 429、413ms、baselineへfallback |
| hidden-condition | 暗所で起こらない条件 | 未送信 |
| formula-scope | 数式と適用範囲 | 未送信 |
| negated-distinction | 否定で決まる比較の違い | 未送信 |

Gemini3.6/minimal、各5秒、逐次、retryなし、最大4問。31秒は送信の間隔で、deadlineとは別に扱う。今回は最初で停止したため間隔待機は発生していない。

保存できた違反情報:

- HTTP429 / RESOURCE_EXHAUSTED
- quota tier分類: free
- quota window分類: day
- quota上限:20
- retrySeconds:68,882

これは返された違反情報の観測で、アカウント全体の課金設定・他モデルの上限・残量を管理画面で監査したものではない。31秒のpacingは分あたりの集中を減らすためで、日次quotaを増やすものではない。

[公式rate limit資料](https://ai.google.dev/gemini-api/docs/rate-limits)によれば、quotaはAPIキー単位ではなくプロジェクト単位で、日次枠は太平洋時間の深夜にresetする。今回のretry秒はAPIの目安であって確定した予約や再開予定ではない。同じプロジェクトのキーを作り直して上限回避を試みる必要はない。

## 品質評価とテストの区別

今回valid proposalは0件。fallbackで元の3参照に必須事実2/2が残るが、モデルが正しく選択したという評価ではない。前回の生物2問の成功も別の限定結果として保持し、今回の4問全部が成功したと合算しない。

無料枠待ちの間、4問題それぞれで、次の模擬提案をテストした。

1. 正しい段落IDを返しながら必須事実が含まれる参照を省く提案。構造検証は通過するが、独立ラベル評価は欠落を検出する。製品ゲートは閉じ、safeReferencesはbaselineを維持。
2. 全参照を保持する提案。全文に必要情報が残ることを確認する。

これは検証契約・安全制御の回帰で、実モデルの意味判断の成功ではない。評価ラベルはモデルへ送信しない。witness段落の関連性、最終回答、実教材、人間/教師ラベル、blind holdoutは未評価。

関連46件のテスト成功。独立安全/コードレビューも問題なし。全Workerテスト978/978成功（約43.1秒、失敗・skipなし）。iOS・実iPadは今回未実施。

## 再開手順

1. 無料枠が回復してから、同じ4問を1回ずつ再測定する。今回以降は外部リクエストを追加していない。
2. 急いで進める場合は、[Google AI Studioの利用上限](https://aistudio.google.com/rate-limit?timeRange=last-28-days)でAPIキー所属プロジェクトを確認し、必要なら[公式billing手順](https://ai.google.dev/gemini-api/docs/billing)で有料利用を検討する。課金設定は今回変更していない。
3. 再測定では形式成功と、選択した全文の必須事実・条件・数式の保持を別々に数える。成功分だけを一般精度として報告しない。
4. 問題なければ未見教材と最終回答まで評価し、製品への接続は別工程として判断する。

`mcp-server`で、既存key fileを環境変数に指定して実行する（キー値はコマンドに書かない）:

```sh
STUDIQUO_RAG_PROPOSAL_REMOTE=true STUDIQUO_RAG_KEY_FILE=/path/to/local/.dev.vars node scripts/rag-quality/paragraph-proposal-live.mjs /private/tmp/paragraph-coverage.json
node --test src/rag-paragraph-proposal.test.js src/rag-selection-proposal-live.test.js
npm test
```

## 安全・運用

プロセスは終了し、自動再試行・後日の自動実行は設定していない。APIキーやprompt、原文、自由エラー文の新規保存なし。使用tokenのusageMetadataは今回取得できず、失敗callの費用は不明。freeという違反分類だけから費用0と断定しない。

プライバシーポリシー・データ削除・本番公開状態の変更はない。ロールバックは評価用のpacingとerror情報追加を戻す範囲で、サーバー操作は不要。段落ID方式は引き続きshadowのみ、productionEligible=falseを維持する。
