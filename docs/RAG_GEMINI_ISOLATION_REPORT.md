# Geminiの503原因切り分け（2026-10-10）

**APIキー不正やJSON指定全般の非対応を示す結果ではない。** 同じ3.6モデル・キー・生成設定で、短い回答・簡単なJSON・1参照の出典選択は成功した。5参照に厳密なschemaを付けた場合だけ503となり、エラーmessageには混雑を示す表現が含まれていた。直後の短いcontrolは成功した。

これは一時的なサービス容量問題を支持する観測だが、**schemaと大きな入力の組み合わせの影響を除外できない**。schemaが原因と断定も、問題が解消したと判断もできない。公開RAG/チャットの設定は変えていない。

## 計画・安全・実装

ユーザーの『①Geminiの原因切り分け』を対象とする。外部API/秘密情報を扱うためfullの安全確認とPlanner/Security Reviewer/Code Reviewerによる独立レビューを実施した。作業先 `.worktrees/rag-wip`、ブランチ `codex/rag-wip`。

新規 `mcp-server/scripts/rag-quality/gemini-isolate.mjs` で5段階の比較を実装した。固定gemini-3.6-flash、temperature1、thinking minimal、maxOutputTokens4096を揃える。各20秒の観測上限、逐次・retryなし、最大6callにpost-controlも含む。401/403/429は即停止。5xxまたはtimeoutなら短いpost-controlを最大1回だけ実行して停止する。最初のcontrolが失敗したらpost-controlも行わない。

非2xx本文は16KiB、2xx本文は64KiB、生成textは32KiBに制限する。HTTP statusを本文より先に保存し、本文が不正でも停止判定はstatusを優先する。キーは既存設定からメモリへ読み、固定GoogleURLのheaderだけに送信。redirectは禁止。secret/prompt/原文/model回答/自由エラー文/project情報をログや結果に保存しない。

エラーをメモリで解析し、既存safeErrorの固定項目と、混雑/形式に関する語を含むかという二つのbooleanだけを保存する。このhintは分類結果であり、完全な原因説明ではない。完成応答、control JSONの妥当性、proposalの原文span検証を別項目にする。

使用資料は既存合成fixtureの生物比較。実ユーザー教材、実紙、Cloudflareの検索データは使わない。正解ラベルはモデルへ送らない。

## 実測

| 段階 | 入力/出力形式 | HTTP | 時間 | 検証 |
| --- | --- | --- | --- | --- |
| A | 極小control、schemaなし | 200 | 1,394ms | 完成・control JSON正しい |
| B | Aと同じprompt、簡単なschemaとJSON MIME | 200 | 2,205ms | 完成・control JSON正しい |
| C | 出典選択schema、合成1参照 | 200 | 1,800ms | proposal形式・原文span正しい |
| D | 生物比較5参照、JSON MIME、schemaなし | 200 | 2,924ms | 完成したがinvalid_spanで不採用 |
| E | Dと同じ入力・設定にschemaのみ追加 | 503 | 2,095ms | UNAVAILABLE、capacityMentioned=true |
| F | 503後の短いcontrol | 200 | 1,049ms | 完成・control JSON正しい |

最大枠の6callで終了し、失敗したEを再試行していない。Eの後にもう一度失敗しても追加controlを続けない。成功5件は全て5秒未満だった。ただし20秒を許した診断であり、5秒deadlineでの継続運用品質は別に測る必要がある。

D/Eは同じ質問・参照全文・順序・snapshot・system/user prompt・temperature・thinking・出力上限で、差はresponseJsonSchemaだけ。時点と確率的生成は異なるので、単発のD成功/E失敗からschemaの因果を確定しない。B/Cはprompt・要求内容・入力も異なり、schema複雑性だけの比較ではない。

## 分かったこと・分からないこと

- キーと現行モデルはこの測定中に利用できた。誤ったキーや全面的なモデル利用不能が今回の主要な説明とは考えにくい。
- 簡単なschemaと、出典選択schemaの小入力は正常に生成できた。JSON/schemaそのものが常に失敗するわけではない。
- 503で返されたstatusはUNAVAILABLEで、混雑の表現を検知した。[公式トラブルシューティング](https://ai.google.dev/gemini-api/docs/troubleshooting)でも503を一時的な失敗として扱う。ただしGoogle側の内部状態・割当残量・課金管理画面は確認していない。
- 全入力でのschemaなし応答は成功したため、5参照の質問自体が全面的に生成不能という結果ではない。
- Dでは**原文引用の検証に失敗した**ため、安全な検証器が提案を拒否した。503とは別の、文字位置・引用文字列をモデルに返させる方式で検証不合格が起きた。位置・quote一致・型・長さ・絵文字境界等のどの検証条件に違反したかは、raw出力を保存していないため本結果から特定していない。位置計算の負担は改善仮説であり原因と確定していない。自動修復して合格扱いはしていない。
- 1参照での形式成功は意味の網羅性・検索精度の保証ではない。5参照で利用できる選択案はまだ得られていない。
- 過去の429の具体的quotaやtimeoutの原因は、今回成功したことだけでは判明しない。

## 検証・費用・運用

新規テスト `mcp-server/src/rag-gemini-isolate.test.js` の10件成功。D/Eの差の限定、hint非漏洩、最大回数、status優先停止、post-control1回上限、本文上限/timeout、形式判定を確認。全Workerテスト948/948成功（約45秒、失敗・skipなし）。独立安全/コードレビューは問題なし。iOS・実iPadは今回未実施。

観測できた成功5callの使用量は入力1,968、回答585、total2,553 token。thoughtsはAPIで未記載であり、その欄を勝手に別消費として加算しない。503のusageは不明。費用は[公式価格表](https://ai.google.dev/gemini-api/docs/pricing)と請求画面を照合する必要があり、usage未取得の失敗分を費用0として扱わない。

プロセスは終了。キーの一時ファイルは作らず、結果には固定項目/数値/booleanだけを保存した。migration/binding/secret/公開flag/DB/Vectorize/プライバシーポリシーの変更はない。ロールバックは診断ファイルを取り除く範囲で、サーバー操作は不要。

## 次の対応

503には、利用不能を検知してfallbackし、検証時は上限を決めた間隔付き再測定を行う。盲目的に連続送信しない。現行public retrievalは維持する。

出典選択は、モデルに文字位置を計算させる負担を減らす設計を検討する。例えばサーバーが段落のIDと原文位置を先に確定し、モデルにはIDを選ばせる。原文・出典の対応は決定的に検証できるが、必要な説明の漏れは別の正解ラベル評価が必要。これは次工程の提案で、今回は変更していない。

厳密なschema+5参照が利用できるかの再確認と、段落ID方式の形式/意味/時間/費用評価を行うまで、AI出典削減を公開RAGへ接続しない。

再実行（既存ローカルkey fileを環境変数に指定、合成のみ）:

```sh
STUDIQUO_RAG_PROPOSAL_REMOTE=true STUDIQUO_RAG_KEY_FILE=/path/to/local/.dev.vars node scripts/rag-quality/gemini-isolate.mjs /private/tmp/gemini-isolation.json
node --test src/rag-gemini-isolate.test.js
npm test
```
