# Standard有料化(年額980円)

状態: **実装済み・無効**。`PaywallConfiguration.isEnabled`(アプリ)と`PAYWALL_ENABLED`(Worker)がどちらもオフの間は、挙動は従来と同じ(全員がStandard、ペイウォールなし)。

## 方針

- 決済はApp内課金(RevenueCat+StoreKit)のみ。アプリ内にカード番号の入力欄は作らない。Web決済(Stripe)は後から追加する。
- 新規ユーザーは、Standard年額の導入オファー(無料トライアル)で最初に無料期間を得る。トライアルの長さと「1つのApple IDで1回」の制限はApp Store側が管理する(サーバーに試用状態は持たない)。
- 無料期間のあとはアプリ全体を購読必須にする(`PaywallGate`)。購読もなく既存ユーザーでもない場合、Workerのプランは`free`になり、AIは402を返す。
- 既存ユーザーは`legacy_standard_accounts`に登録し、購読なしでもStandardにする。期限は設けていない。

## 有効化の前提(手作業)

1. App Store Connect: `com.yabuko.studiquo.standard.yearly`(年額980円)を作り、導入オファーに無料トライアルを設定する。
2. RevenueCat: Entitlement `standard` を作り、上の商品を紐付ける。Offeringに含める。
3. D1 migration `0006_legacy_standard_accounts.sql` を適用する。
4. **有効化の直前に**、その時点の既存アカウントを`legacy_standard_accounts`へ登録する(下記)。
5. Worker に `PAYWALL_ENABLED=true` を設定する。
6. アプリの `PaywallConfiguration.isEnabled` を `true` にしてビルドする。

順序が重要: 4の前に5を行うと、既存ユーザーが`free`になりAIが402を返す。旧アプリ(ペイウォールなし)は、402を通常のAIエラーとして表示する。

### 既存アカウントの登録

セッションの`sub`は、Apple=素のsub、Google=`google:<id>`、メール=`email:<id>`、リンク済みは`identity-canonical:<sub>`が指す正規のsub。KVの次のキーを列挙し、`sub`に直して登録する。

- `account:<sub>` → `<sub>`
- `account:google:<id>` → `google:<id>`
- `account:local:<id>` → `email:<id>`
- `identity-canonical:<alias>` の値 → そのまま(正規sub)

```bash
cd mcp-server
npx wrangler kv key list --binding STUDIQUO_DATA --prefix account: --remote
npx wrangler d1 execute studiquo-admin --remote --command \
  "INSERT OR IGNORE INTO legacy_standard_accounts (app_user_id, granted_at) VALUES ('<sub>', strftime('%s','now')*1000)"
```

自動化していない。ユーザー数が少ないうちに手で行うか、数が増える前にスクリプト化する。

## ロールバック

- 停止: Workerの`PAYWALL_ENABLED`を外す(即時)。アプリのフラグがオンでも、`/api/plan`の`paywallRequired`が偽になり、全員がStandard扱いになる。※アプリ側は現状この値を読んでおらず、サーバーのプランが`standard`で返るため同じ結果になる。
- migrationは追加のみ。テーブルは残してよい。

## 残り(未実装・要判断)

- AI以外のサーバー機能(同期、チャット、共同編集)は、サーバー側では購読を強制していない。強制するのはアプリのペイウォールのみ。
- Web決済(Stripe Checkout)は未着手。外部リンク誘導の手数料と文言は、Appleの日本向け規定を確認してから設計する。
- 既存ユーザーのStandardをいつまで無料にするか(現状は期限なし)。
- `/api/plan`のルートテストは未追加(`getPlan`の挙動はentitlements.test.jsで検証済み)。
