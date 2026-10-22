# AIクレジット制とPlus/Proのモデル

状態: **Worker・アプリとも実装済み。基盤はOpenAI**（2026-10-12にGeminiから切替。経緯は`openai-base-provider.md`）。Claudeは無効。`AI_PROVIDER_APPROVED`は`false`のまま。

## プラン(2026-10-12決定。Plus/Proの価格は仮置き)

| | Standard | Plus | Pro |
|---|---|---|---|
| 価格(仮) | 年額980円 | 月額600円 / 年額5,800円 | 月額1,500円 / 年額14,800円 |
| モデル | ChatGPT Luna | + ChatGPT Terra・Sol | + ChatGPT Astra |
| 1週間(クレジット) | 30(Lunaで30回) | 350 | 920 |
| 5時間 | 10 | 100 | 250 |
| 1分(回数) | 5 | 10 | 20 |

2026-10-22: 1日・1か月の窓を1週間に置き換え、入力の長さに応じた加算(AI-2)と、購読者数に比例するプラン別の全体上限(AI-3)を入れた。数値は`mcp-server/src/ai-limits.ts`に集め、環境変数`AI_LIMITS`で上書きできる。週の値は旧月の値を週あたりに直したもの(×7/30.4)。

モデルごとの消費クレジット: Luna 1 / Sol 20 / Terra 22 / Astra 100(Claudeは無効。重みは表に残してある: Sonnet 20 / Opus 40)(1クレジット≒$0.0007。1回あたり入力3,000・出力800トークンで算出、価格は2026-10-12の各社の価格ページ)。機能の倍率: チャット1 / 採点基準2 / 採点3 / 復習3。

毎週の枠を使い切ったときの1か月の原価の上限は、Plusで約$1.07、Proで約$2.80(売上の約4割以下を目安に設計)。入力が長いリクエストは多く数えるので、この上限は入力の長さによらず保たれる。1回の費用が5時間の枠を超えるリクエストは、413(`code: "input_too_long"`)で断る(待っても送れないため429にしない)。チャットは、そのプランとモデルで払える量まで古いターンを落として送る。

配備の注意: 旧い全体上限の変数`GLOBAL_CHAT_DAILY_LIMIT`・`GLOBAL_GRADING_DAILY_LIMIT`・`GLOBAL_REVIEW_DAILY_LIMIT`は読まなくなった。ダッシュボードに設定してあれば削除する(2026-10-22時点の本番には無い)。

## どこを直すか

- 重み: `mcp-server/src/ai-credits.ts`。上限・入力の加算・全体上限: `mcp-server/src/ai-limits.ts`(または`AI_LIMITS`)。モデル: `PLAN_MODELS`(`ai.ts`)。
- アプリの表示: `AIModelCatalog.swift`(モデルとクレジット)、`PlanAllowance.swift`(上限)。**手で合わせる。**
- OpenAIのモデルID: `wrangler.jsonc`の`OPENAI_*_MODEL`(Luna=`gpt-6-luna`、Terra=`gpt-5.6-terra`、Sol=`gpt-6.1-sol`、Astra=`gpt-6-astra`)。OpenAIのモデル名は世代が混在しているため、使う前にアカウントで呼べることを確認する。
- Claudeはどのプランにも載せていない（利用ガイドラインが未成年向けアプリの条件を満たしてから足す）。

## 動き

- 数える単位はアカウント(`usage-account:<sub>`のハッシュ)。以前の「端末ごと・機能ごと・1日」の上限は廃止。サービス全体の`GLOBAL_*_DAILY_LIMIT`(回数)も廃止し、プランごとのクレジットの上限(`ai-limits.ts`の`global`)に置き換えた。
- 上限に達すると429(`code: "ai_limit"`、`window`)。1分とサービス全体は`Retry-After: 60`付き。
- 1週間・5時間・1分は、どれも最初の利用から数える固定の窓(暦ではない)。
- Standardの枠は週30クレジット。基盤がLuna(重み1)なので、Lunaの短いチャット30回分。
- 数えたカウンターは、アカウント削除では消さない(ハッシュのみで、期間が過ぎると自動で消える。削除→再登録で週の枠が戻るのを防ぐ)。
- 複数の窓のどれかが断ると、他の窓で取った分を、取った窓にだけ返す(`RateCounter.take` / `give`、`counter-state.js`)。入力が不正なリクエストは課金せず、チャットで上流が断ったときは返す。

## Claude（Anthropic）を足す手順(別工程)

1. Anthropicの利用ガイドライン・年齢条件を確認し、AI送信の同意文・プライバシーポリシー・App Storeのプライバシー申告にAnthropicを加える。
2. `AIDataDisclosure.currentVersion`とWorkerの`AI_CONSENT_VERSION`を新しい版に上げる。
3. `PLAN_MODELS`（`ai.js`）と`AIModelID`/`AIModelCatalog`にClaudeを足す。`ANTHROPIC_API_KEY`を`wrangler secret put`する。

## 未実装

- アプリに残りクレジットを表示する(`GET /api/ai/usage`のようなAPIが必要)。今は上限に達したときのエラー文のみ。
- 採点・復習の倍率(2・3)は目安。実際のトークン量を見て調整する。
- 採点などの途中で上流が失敗した場合の返却は、まだない(チャットの上流エラーと入力エラーは対応済み)。
