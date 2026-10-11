# AIクレジット制とPlus/Proのモデル

状態: **Worker・アプリとも実装済み。他社モデルは無効**(`AIModelCatalog.thirdPartyModelsEnabled = false`、Workerは`ai-privacy.js`がGoogle以外を拒否)。Geminiのみのリリースなら、このまま出せる。

## プラン(2026-10-12決定。Plus/Proの価格は仮置き)

| | Standard | Plus | Pro |
|---|---|---|---|
| 価格(仮) | 年額980円 | 月額600円 / 年額5,800円 | 月額1,500円 / 年額14,800円 |
| モデル | Gemini | + Claude Sonnet 5.5、ChatGPT Luna・Terra・Sol | + Claude Opus 5.5、ChatGPT Astra |
| 1か月(クレジット) | 30 | 1,500 | 4,000 |
| 1日(日本時間) | 15 | 600 | 1,500 |
| 5時間 | 10 | 400 | 1,000 |
| 1分(回数) | 5 | 10 | 20 |

モデルごとの消費クレジット: Gemini 1 / Luna 1 / Sonnet 20 / Sol 20 / Terra 22 / Opus 40 / Astra 100(1クレジット≒$0.0007。1回あたり入力3,000・出力800トークンで算出、価格は2026-10-12の各社の価格ページ)。機能の倍率: チャット1 / 採点基準2 / 採点3 / 復習3。

月間分を使い切ったときの原価の上限は、Plusで約$1.05、Proで約$2.80(売上の約4割以下を目安に設計)。

## どこを直すか

- 重み・上限・モデル: `mcp-server/src/ai-credits.js`(Worker、実際の強制)と`PLAN_MODELS`(`ai.js`)。
- アプリの表示: `AIModelCatalog.swift`(モデルとクレジット)、`PlanAllowance.swift`(上限)。**手で合わせる。**
- OpenAIのモデルID: `wrangler.jsonc`の`OPENAI_*_MODEL`(Luna=`gpt-6-luna`、Terra=`gpt-5.6-terra`、Sol=`gpt-6.1-sol`、Astra=`gpt-6-astra`)。OpenAIのモデル名は世代が混在しているため、使う前にアカウントで呼べることを確認する。
- Sonnetは`claude-sonnet-5-5`。旧IDの`claude-sonnet-5`、Haiku、`openai-mid`・`openai-flagship`は表から外した(アプリは常にGeminiを送っていたため影響なし)。

## 動き

- 数える単位はアカウント(`usage-account:<sub>`のハッシュ)。以前の「端末ごと・機能ごと・1日」の上限は廃止。環境変数`CHAT_DAILY_LIMIT`などの上書きもなくなった(サービス全体の`GLOBAL_*_DAILY_LIMIT`は残す)。
- 上限に達すると429(`code: "ai_limit"`、`window`)。1分とサービス全体は`Retry-After: 60`付き。
- 1日・1か月は日本時間の暦で数える。5時間と1分は最初の利用から数える固定の窓。
- 数えたカウンターは、アカウント削除では消さない(ハッシュのみで、期間が過ぎると自動で消える。削除→再登録で月の枠が戻るのを防ぐ)。
- 複数の窓のどれかが断ると、他の窓で取った分は返す(`RateCounter.release`)。

## 他社モデルを有効にする手順(別工程)

1. AI送信の同意文(`AIDataDisclosureView`)に、AnthropicとOpenAIへ送ることを書き、プライバシーポリシーとApp Storeのプライバシー申告を更新する。
2. `AIDataDisclosure.currentVersion`と、Workerの`AI_CONSENT_VERSION`(`ai-privacy.js`)を新しい版に上げ、`ai-privacy.js`のGoogleのみの拒否を、承認した提供先へ緩める(`ai-privacy.test.js`も直す)。
3. 提供元の契約・利用年齢の確認を終えて、`AI_PROVIDER_APPROVED`を有効にする。
4. `ANTHROPIC_API_KEY`・`OPENAI_API_KEY`を`wrangler secret put`する。
5. `AIModelCatalog.thirdPartyModelsEnabled`を`true`にする。

## 未実装

- アプリに残りクレジットを表示する(`GET /api/ai/usage`のようなAPIが必要)。今は上限に達したときのエラー文のみ。
- 採点・復習の倍率(2・3)は目安。実際のトークン量を見て調整する。
- Geminiの原価は未確認(重みは1としている)。
