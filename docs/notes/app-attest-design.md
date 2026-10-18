---
title: App Attest 設計
date: 2026-10-18
tags: [security, design, app-attest]
---

# App Attest 設計

AIプロキシとサインイン・登録系を、「正規のStudiquoアプリからの要求か」で守る。実装は`mcp-server/src/app-attest.js`、テストは`app-attest.test.js`。

## 範囲

- 保護する経路(POSTのみ): `/api/ai/*`、`/api/auth/apple`、`/api/auth/google`、`/api/auth/email/send-code`、`/api/auth/email/confirm-code`、`/api/auth/local/login`、`/api/passkeys/login/options|verify`。
- 守れないもの: 本文の改ざん(署名は方法・パス・時刻だけに掛かる。改ざん対策はTLS)、正規端末を乗っ取った人による利用、脱獄端末での偽装(Appleの判定の限界)。

## 流れ

1. `POST /api/attest/challenge` → Workerが署名付きの使い捨て風チャレンジを返す(`<ms>.<乱数>.<HMAC>`、5分有効、サーバーに状態を持たない)。署名鍵は`TOKEN_SIGNING_KEY`を別ラベルで使う。
2. アプリがSecure Enclaveで鍵を作り、チャレンジのSHA-256を`clientDataHash`にして`attestKey`する。`POST /api/attest/register`に`keyId`・`attestation`(CBOR)・`challenge`を送る。
3. Workerの検証: 証明書チェーン(葉→中間→Apple App Attestation Root CA。ルートはコードに埋め込み、SHA-256を固定)、有効期限、nonce拡張(`SHA256(authData ‖ SHA256(challenge))`)、`keyId`=公開鍵のSHA-256、`rpIdHash`=`SHA256(APP_ID)`、counter=0、AAGUID(本番`appattest`。開発は`APP_ATTEST_ALLOW_DEVELOP=true`のときだけ)、credentialId=keyId。通れば公開鍵とcounterを`RateCounter`のDO(`attest-key:<keyId>`)に保存する。同じ鍵の再登録は409。
4. 以降、保護経路の要求は`x-studiquo-attest: <keyId>.<時刻ms>.<assertion>`(すべてbase64url)を付ける。assertionは`METHOD\npath\n時刻ms`に対するもの。Workerは時刻のずれ(±5分)、署名、`rpIdHash`、counterの増加を確認し、DOでcounterを原子的に進める(同じcounterの2要求は片方だけ通る)。

## 動作モード(`APP_ATTEST_MODE`)

- `off`(既定): 何も検査せず、attestの2経路は404。`APP_ATTEST_APP_ID`・`TOKEN_SIGNING_KEY`のどちらかが無くてもoff。
- `log`: 検査して1行ログ(`app attest`、結果は`ok`/`absent`/`malformed`/`stale`/`unknown_key`/`replay`/`invalid`/`error`)を出すだけ。拒否しない。
- `enforce`: `ok`以外は403(`app_attest_required`)。

導入順: Worker配備(off)→アプリ配布→`log`で`absent`が消えるのを観察→`enforce`。

## 互換性

- 旧版アプリ: ヘッダが無い=`absent`。`off`/`log`では今まで通り通る。`enforce`の前に`MIN_APP_BUILD`で旧版を止めるか、`absent`が無いことを確認する。
- 新版アプリ+旧Worker: attest経路が404になる。アプリ側は失敗を無視して従来通りに送る作りにする(アプリ実装時の要件)。
- 追加型のみ。DOのstorageに新しいキー`attest`を足すだけで、マイグレーションは不要。

## 脅威と障害

- チャレンジの再利用: 登録はkeyIdごとに1回のため、同じ登録の再送は409。assertionはcounterで再送を防ぐ。
- 登録の先取り(他人のkeyIdを先に登録する): 登録にはAppleが署名したattestationが要り、nonceにチャレンジが入るため、他人の鍵では作れない。
- 登録の洪水: IPごとのレート制限(`RATE_LIMIT_ATTEST_CHALLENGE`10/分、`RATE_LIMIT_ATTEST_REGISTER`5/分)。保護経路でヘッダが無い要求はDOを呼ばない。ヘッダがある要求はDOを呼ぶため、その前にIPごとの`RATE_LIMIT_ATTEST_ASSERT`(300/分)を挟む。
- 再インストール・端末移行: 鍵が変わるので再登録が必要(アプリ側で鍵IDをKeychainに持ち、無い・拒否されたら作り直す)。
- DO障害・遅延: `assessAssertion`は例外を握りつぶして`error`を返す。`log`では通り、`enforce`では403になるため、`enforce`にする前に`error`の頻度を確認する。
- 中間証明書の基本制約は見ていない(ルートを固定しているため。Appleの発行物のみが連鎖する前提)。

## enforce前に守ること(アプリ側の要件)

- assertionは送信のたびに作る。通信の再送(自動リトライ)では作り直す。同じヘッダの再送はcounterが進んでいるので`replay`で拒否される。
- assertionの生成は直列化する。並行に作ると、後から作ったcounterが先に着いて、先のものが`replay`になる。
- ヘッダの時刻は送信の直前に決める(±5分を超えると`stale`)。
- 403の`reason`が`unknown_key`なら鍵を作り直して再登録する。`error`相当は503で、再試行してよい。
- 登録の201を受け取れず再送して409になったら、成功扱いにするか鍵を作り直す。
- `log`で`replay`・`stale`・`error`の頻度を実測してから`enforce`にする。

## ロールバック

`APP_ATTEST_MODE`を`off`に戻して再配備(またはwranglerのvars変更)するだけで、検査は止まる。保存した鍵は害にならず、残してよい。

## 残り(別作業)

- iOS側: `DCAppAttestService`で鍵作成・attest・assertion、鍵IDのKeychain保存、`com.apple.developer.devicecheck.appattest-environment`のentitlement(`project.yml`と生成後の確認)、全リクエストへのヘッダ付与。シミュレータは非対応のため実機でのみ確認できる。
- ステージングに`TOKEN_SIGNING_KEY`が無いため、ステージングでは`off`のまま。検証するには鍵の設定が要る。
- 実機での登録・assertionの成功率の確認(人の手が必要)。
- 将来の検討: 鍵ごとの利用予算、使われない鍵の棚卸し(DOにalarmが無い)、`TOKEN_SIGNING_KEY_OLD`でのチャレンジ検証(ローテーション直後5分は登録が失敗する)。
- `RATE_LIMIT_ATTEST_*`は配備時にCloudflare側で作られる(namespace_id 1025〜1027、staging 2025〜2027)。

Up: [notes 目次](INDEX.md)
