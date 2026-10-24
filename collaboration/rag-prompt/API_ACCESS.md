# Lunaの評価費用とキー設定（招待送信済み・本人承諾待ち）

2026-10-18 更新: ユーザーの再度の招待指示を受け、OpenAI組織の表示名をPersonalからStudiquoへ変更。Readerで組織招待し、Invite to projectsはstudiquo-rag-evaluationだけを選択、Default projectは選択解除を確認して送信。Invitations一覧に対象を確認、本人承諾待ち。評価projectは作成済み。キー作成/共有・予算/モデル設定・有料APIは未実施。個人メールは資料へ複写しない。

次は本人が招待を承諾し、評価projectのMember権限を確認する。組織全体のOwnerやDefault project権限を推測で付けない。キー作成は本人が行い、友人PCへの保存と実行adapter/予算合意を別に確認する。公式の[project権限](https://developers.openai.com/api/docs/guides/rbac)と[inviteのproject指定](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/invites/methods/create)を参照。

2026-10-18。既存の評価用キーを友人の担当にも使う依頼に対する準備。秘密値は読取・出力・複製していない。共有経路/招待先と友人PC設定は未確定。現在のworkspace.mjsはoffline専用で、キーを設定しただけでは回答生成しない。

## 共有方法

費用を同じ評価projectで管理する目的なら、既存の評価projectへ友人を招待し、友人本人のproject keyを作る構成を推奨。元のキーはそのまま使い続けられ、友人分は別キーで停止・追跡しやすい。GitHub collaborator権限はOpenAIのproject権限を付与しない。

既存の同じキー自体を使う場合は、ユーザーが指定したパスワード管理アプリ等の秘密共有か、友人PCへの直接設定を使う。キーをGitHub/Notion/このチャットへ貼らない。共有先が決まるまで既存.dev.varsの秘密値は読み出さない。既存キーで使えるproject・モデル・権限・期限は別途確認する。本番資格情報やadmin keyを友人に渡す必要はない。

同じキーを使うと、キー単位の利用記録だけからあなたと友人を区別できない。友人用の月$5を同じキーだけに自動適用できるとは説明しない。ラン単位の台帳とprojectの利用量を照合する。ローカル設定ファイルだけではキーの他用途利用を防げない。

OpenAI側で可能な範囲でLunaだけにモデル利用を限定し、Responses生成に必要な権限だけを付与する。Dashboardで使用できる権限・model controlsを確認する前に設定完了としない。

## 推奨予算（未承認・未設定）

| 範囲 | 推奨 |
| --- | --- |
| 初回1候補のラン | $1以内、まず24呼出し。反復するなら最大72呼出しを計画に記録 |
| 友人の月間評価枠 | $5を提案。あなたの既存評価費用とは別に集計 |
| 30問まで広げる段階 | 360呼出しなら約$2.20の試算。初回$1ランへ混ぜず、別の$3程度の計画として承認 |

新しい購入・残高追加・課金設定変更はしていない。この文書は予算の提案であり、有料生成を自動承認/開始する設定ではない。

## 価格と試算

2026-10-18に[公式Lunaモデルページ](https://developers.openai.com/api/docs/models/gpt-6-luna)を確認。`gpt-6-luna`の通常テキスト料金は入力$0.10/100万token、出力$0.50/100万token。272Kを超える長い入力やFast/地域処理等は別料金なので、この評価では使わない。cache割引・Batch割引は試算へ入れない。

1呼出しにつき入力20,000token、出力上限8,192token（reasoningを含む課金出力）と仮定すると、`20,000×0.10/1,000,000 + 8,192×0.50/1,000,000 = $0.006096`。

| 試験 | 呼出数 | 上記仮定での概算 |
| --- | --- | --- |
| 固定6ケース × 2style × 現行/候補各1回 | 24 | $0.146304 ≒ $0.15 |
| 上記を3反復 | 72 | $0.438912 ≒ $0.44 |
| 開発30問 × 2style × 2候補 × 3反復 | 360 | $2.194560 ≒ $2.20 |

入力20,000tokenは今回測定した実token数ではなく試算条件。料金変更・retry・追加reviewモデル・画像/検索/embedding等の費用は別。実行前に全要求のtoken上限と予算予約を確認する必要があり、この表だけを厳密な課金上限として扱わない。円換算は為替・税・決済条件で変わるのでUSD管理とする。

## 友人へ提示する実行条件

- モデルは`gpt-6-luna`、`reasoning.effort=medium`、`service_tier=default`、`store=false`。固定比較bodyの出力上限8,192を両候補でそろえる。他モデルへ自動fallbackしない。
- 最初はkit内の固定6ケース、source_only/explain、凍結baseline対候補1つ。質問/履歴/根拠/生成設定を変更せず、指示追加だけを比較する。
- 実行前に候補hash・context hash・call数・反復数・費用上限を固定。先に出す候補を交互にし、実行順を記録する。未使用20問は調整に使わない。
- 同時実行1。成功/失敗/timeoutを含む送信を数え、送信前に最大費用を予約する。run上限またはcall上限に達する前に停止。失敗・応答不明・保存失敗を自動再送しない。再開は既存journal照合後に行い、予算台帳をリセットして回避しない。
- 友人の月間利用額はproject側の実usageでも照合。共有キーでは他担当の消費も混ざるため、project全体の上限変更は影響を確認してから行う。
- [公式spend limits](https://developers.openai.com/api/docs/guides/spend-limits)では、通知だけのalertと通信を止めるhard limitを区別する。必要なら評価projectだけにhard limitを設定する。反映遅延で少し超える可能性があり、厳密な1セント単位の保証ではない。既存projectへ$5を設定するとあなた側の評価も止まる可能性がある。今回Dashboardは変更していない。
- 生回答・request・キーはprivate保存。共有成果はhash、token/費用、原子的採点の集計と限界。自分が生成した回答を自分の所感だけで採用しない。

## 設定の完了判定

1. 共有経路または同じ評価projectへの招待先が確認できた。
2. 友人が秘密値を露出させず自分の環境変数/秘密管理へ設定した。
3. 実行adapterが固定入力と予算予約・再開/停止・error非漏洩を検証し、必要な独立レビューを通った。
4. 承認された最小試行で接続・課金先・使用量を確認できた。

現時点で1〜4は未完了。キー設定やAPI疎通確認を成功済みとしない。OpenAIの権限とsecret管理の参考: [Production best practices](https://developers.openai.com/api/docs/guides/production-best-practices)、[RBAC](https://developers.openai.com/api/docs/guides/rbac)。
