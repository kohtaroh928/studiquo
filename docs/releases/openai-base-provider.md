# AIの基盤をOpenAIに切り替える

状態: 実装済み（Worker・アプリ）。`AI_PROVIDER_APPROVED=false`のまま。デプロイ・マージはしていない。

## なぜ

Gemini API / Vertex AIの利用条件が、18歳未満を対象とする、または18歳未満が使う可能性が高いアプリでの利用を認めていない。学生向けのstudiquoは該当するため、基盤をOpenAI（Standard = ChatGPT Luna）にした。

## 方針（2026-10-12承認）

- 基盤はOpenAI。13歳未満はAIを使えない。13〜17歳は保護者の同意の確認を必須にする。
- Claude（Anthropic）はどのプランにも載せない。Geminiのコードと変数は削除した。
- 採点基準・採点・復習の3機能もLunaで動かす（構造化出力＝JSON Schema strict）。

## 変更点

Worker:
- `openai.js`: Responses APIの構造化出力、429/5xxの再試行（3回）、`safety_identifier`、モデレーション。
- `ai.js`: Gemini呼び出しを削除。`PLAN_MODELS`はStandard=Luna、Plus=+Terra・Sol、Pro=+Astra。画像は`input_image`のdata URLで送る。
- `ai-privacy.js`: 同意の版を`openai-v1`に、`X-Studiquo-Age`（`adult`/`teen`）を必須に。
- `ai-credits.js`: 既定モデルをLunaに。Geminiの重みを削除。
- `legal.js`: 利用規約・プライバシーポリシーにOpenAIと年齢条件を記載。

アプリ:
- `AIModelCatalog`: Luna/Terra/Sol/Astraのみ。`thirdPartyModelsEnabled`を廃止。
- `AIDataDisclosure`: 版`openai-v1`、年齢区分（`AIAgeBand`）を保存。同意画面に年齢の選択を追加（13歳未満は許可ボタンが押せない）。
- `WorkerAIProvider`: `X-Studiquo-Age`ヘッダーを送る。

## 公開前にあなたがやること

1. `OPENAI_API_KEY`を`wrangler secret put`（本番とステージング）。`OPENAI_*_MODEL`のIDがアカウントで呼べるか確認。
2. App Storeの年齢レーティングを13+以上に設定し、プライバシー申告にOpenAI（ユーザーコンテンツの送信先）を加える。
3. 審査メモのGemini/Googleの記述をOpenAI/ChatGPTに直す。
4. ステージングで実機確認後、`AI_PROVIDER_APPROVED`を`true`にする。

## 既知の注意

- 保護者の同意は自己申告の確認であり、年齢を検証する仕組みではない。
- プランを下げた後、以前選んだ上位モデルが残っているとチャットは403になる（ピッカーで選び直す）。従来からある挙動。
- モデレーションは文章（直近20件のユーザー発言とノート本文）だけ。画像は検査しない。モデレーションが落ちているときは通す（fail-open）。
- 年齢区分は端末ごとの自己申告。サーバーは`adult`/`teen`の値を見るだけで、永続記録や`teen`向けの追加制限はない。13歳未満と答えたあとでも、設定から選び直せる。
- 公開の順序: 旧版アプリ（同意`google-v2`・年齢ヘッダーなし）は、`AI_PROVIDER_APPROVED`を`true`にするとAIが403になる。新版アプリの配信後に有効にする。
- 推論モデルは出力上限（チャット8,192・構造化16,384トークン）に推論分も含むため、Terra/Sol/Astraで途中切れが出ないか、実モデルで確認する。
