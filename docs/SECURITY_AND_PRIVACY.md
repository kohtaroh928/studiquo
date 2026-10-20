# Studiquo Security and Privacy

最終更新: 2026-10-07  
状態: 現行実装を基準にした内部設計・運用基準

読み方: 「現行」「現在」は開発ブランチの実装を指し、本番へ反映済みとは限らない。独立レビューを実施し、指摘に基づく修正を進めている。公開手順と未完了項目は`PRIVACY_RELEASE_CHECKLIST.md`を参照する。

## 1. 目的と適用範囲

この文書は、Studiquoで扱う情報、信頼境界、セキュリティ制御、プライバシー上の要件、保持・削除方針、変更時の確認事項を定義する。
対象はiPadアプリの`studiquo/`とCloudflare Workerの`mcp-server/`である。

この文書は、利用者向けプライバシーポリシー、App Storeのプライバシー申告、外部サービスとの契約、法的助言の代替ではない。それらの内容と実装を一致させるための技術上の正本として使う。

実装と本文が食い違う場合は、安全側の挙動を維持したうえで差異を記録し、コード、テスト、利用者向け説明を同じ変更で更新する。

## 2. 基本原則

- 必要な情報だけを、明示した目的のために扱う。
- 認証済みであることと、対象データへの権限があることを分けて検証する。
- クライアント入力、外部MCP入力、Webhook、AI出力、ファイル、URLを信頼しない。
- 秘密情報をアプリ、Git、ログ、スクリーンショット、テストfixtureへ入れない。
- 保存する前に、保存先、保持期間、削除方法、アカウント削除との関係を決める。
- 利用者の学習内容を、広告、第三者トラッキング、モデル訓練など別目的へ転用しない。
- 障害時に認証や認可を迂回して継続しない。機密性を可用性より優先する。
- Highリスク変更は脅威、失敗時挙動、ロールバック、互換性、独立レビューを確認する。

## 3. データ分類

| 区分 | 例 | 取り扱い |
| --- | --- | --- |
| Restricted | パスワード、Bearer token、OAuth token、Passkey情報、AI/API secret、APNs鍵、Webhook secret、暗号鍵 | 生の秘密値はKeychainまたはWorker secretsへ保存する。パスワード・tokenの検証用hashやPasskey公開鍵は認証用ストレージに限定する。平文ログ・Git・分析基盤へ出さない |
| Confidential | ノート、OCR、答案画像、文書、スライド、チャット、添付、カレンダー予定、AI会話、問題報告の画像 | 利用者または明示的に許可された相手だけがアクセスする。外部送信前に目的を表示する |
| Personal | メールアドレス、外部ID、表示名、友達関係、端末token、購読状態、利用履歴、IPに由来する制限キー、ログイン元の国・ASNの履歴 | 目的を限定し、識別子は可能な範囲でハッシュ化する。削除経路を持つ |
| Internal | エラーfingerprint、集計済み件数、アプリ・OSバージョン、管理メモ | 運営者だけがアクセスする。本文やアカウント情報を混ぜない |
| Public | 公開お知らせ、法務ページ、公開ドキュメント | 公開前に機密情報と個人情報が含まれないことを確認する |

新しいデータは、保存処理を実装する前にこのいずれかへ分類する。判断できない場合はRestrictedとして扱う。

## 4. システムの信頼境界

```text
利用者
  │
  ▼
iPadアプリ ── SwiftData / CloudKit / Keychain / 端末ファイル
  │ HTTPS
  ▼
Cloudflare Worker ── KV / D1 / Durable Objects
  │
  ├─ Apple / Google / Passkeys / Resend
  ├─ Gemini / Anthropic / OpenAI
  ├─ RevenueCat / APNs
  └─ Slack / Cloudflare Access

外部MCPクライアント ── OAuth 2.0 Authorization Code + PKCE ──▶ Worker
```

境界を越えるたびに、送信主体、目的、データ量、認証、認可、入力上限、保存有無、失敗時挙動を確認する。

## 5. データインベントリ

| データ | 主な保存先 | 外部送信 | 現在の削除・保持 |
| --- | --- | --- | --- |
| ノート、カード、文書、スライド、予定、学習履歴、AI会話 | SwiftData、CloudKit | 選択したAI機能、MCP同期、共有機能で必要部分を送信 | SwiftDataの削除対象。CloudKit構成では同期削除を意図する |
| 自動ノートバックアップ | Application Supportの`studiquo/AutoBackups` | 通常は送信しない | ノートごとに最大5件。アカウント削除時に一括消去 |
| 保護ノートの暗号文 | SwiftData / CloudKit | 通常は送信しない | ノートとともに削除。AES-GCM鍵はiCloud Keychain同期 |
| Workerセッション | 端末Keychain、KVにはtoken hashとsession | Worker API | 90日。ログアウト時に端末から削除し、サーバー失効をbest effortで要求 |
| Apple、Google、メール、Passkeyのidentity | 端末Keychain、KV | 各認証提供者 | アカウント削除処理の対象 |
| メール確認コード | KV | Resendでメール送信 | 15分で失効。コードはhash化して保存。退会時にも削除する |
| パスワードのhash | KV(`account:local:`) | 送らない | Argon2id(移行中は旧PBKDF2も)。退会時に削除。詳細は6.4 |
| 漏えいパスワードの照合 | 保存しない | Have I Been Pwned(パスワードのSHA-1の先頭5文字だけ) | 登録・再設定のときだけ送る。パスワード本体と残りのhashは送らない |
| ログインの失敗回数・待機(アカウント単位、IP+アカウント単位、ASN単位) | `RATE_COUNTER`(メール・IPのhashを名前に使う) | 送らない | 約1時間の窓。IP+アカウント単位は、信頼済みの記録を含めて最大約14日+1時間。アカウント単位は退会時に削除。IP+アカウント単位はIPを列挙できず、自然に失効するまで残る |
| ログイン元の履歴(国+ASN、最大20件) | `RATE_COUNTER`(メールのhashを名前に使う) | 新しい環境のとき、本人へメール(Resend) | 90日。退会時に削除。新しい環境の通知の判定にだけ使う |
| ログイン通知の枠、コード送信・確認の試行回数 | `RATE_COUNTER`(メールのhashを名前に使う) | 送らない | 1日／1時間で失効。退会時に削除 |
| パスワードの世代カウンタ | `RATE_COUNTER`(メールのhashを名前に使う) | 送らない | 整数だけ。退会後7日間残して自動削除(15.2)。再登録で保持に戻る |
| ログインの結果ログ | Workers Logs | 送らない | 結果・国・ASNだけ。メールとIPは含めない。保持はCloudflareの設定による |
| チャット、友達、グループ、添付 | KV、`USER_REGISTRY`、`CHAT_ROOM` | 参加者、APNs | アカウント削除時に参照を除去し、過去発言は匿名化され得る。期間による自動削除は未定義 |
| 共同編集状態 | `DOCUMENT_ROOM` | 許可された参加者 | アカウント削除との完全な保持表は未定義 |
| MCPスナップショット | KV | 接続を許可したMCP client | アカウント削除対象。再同期まで古い内容が残り得る |
| MCP grant、access token、refresh token | KV | MCP client | access tokenは1時間、refresh tokenは90日。grantは取消しまたはアカウント削除まで |
| MCPからの作成要求 | `MCP_INBOX` | iPadへ取り込み | アカウント削除時にpurge。取り込み後は端末データとして管理 |
| AIへの質問、選択資料、画像 | 原則として要求中だけWorkerを通過 | 初期提供先はGoogleのみ | バージョン付き同意必須。提供条件の確認までサーバー既定停止。provider側保持は契約確認が必要 |
| 課金・購読状態 | RevenueCat、D1 | RevenueCat | 購読者情報は退会時削除。購入イベント90日。外部顧客削除は永続ジョブで再試行 |
| 利用量 | D1、`RATE_COUNTER` | 運営集計 | アカウント削除時にD1の利用イベント・初回利用記録を削除。短期counterは期間終了で失効 |
| APNs device tokenと通知設定 | 端末Keychain、KV | Apple APNs | ログアウト、端末登録解除、所有者変更、アカウント削除で削除 |
| 自動エラー診断 | 端末UserDefaults queue、D1 | Worker、Slackへ通知のみ | 既定OFF。個人関連90日、匿名集約180日。OFF時queue削除 |
| 手動の問題報告 | D1、KV | SlackへID・端末情報・管理リンクのみ | 本文・画像90日。閲覧はAccess認証必須。退会時に本人分を削除 |

上表の「未定義」は許容済みの恒久方針ではなく、公開前に責任者、期間、削除jobを決める必要がある項目を示す。

## 6. 認証とセッション

### 6.1 利用者認証

利用者はメールとパスワード、Sign in with Apple、Google Sign-In、Passkeyを利用できる。

- AppleとGoogleのtokenはWorkerで署名、issuer、audience、期限などを検証する。
- メール登録は6桁確認コードによる所有確認を完了してから有効化する。
- パスワードは平文で保存しない。保存はArgon2id(6.4)で、旧PBKDF2のレコードは検証でき、正しいパスワードでログインしたときに書き換える。
- 登録・再設定のパスワードは、長さ8〜1024文字と、漏えいパスワードの照合(6.4)だけで判断する。大文字・記号の必須や、定期変更の強制はしない(NIST SP 800-63Bの方針)。
- Passkey challengeは使い捨てかつ短命とし、origin、RP ID、challenge、counterを検証する。
- 同じ確認済みメールに属するidentityはcanonical accountへ統合する。統合前後の既存sessionにもcanonical identityを適用する。

### 6.2 Studiquoセッション

- Workerが発行した`<発行時刻>.<乱数>`形式の不透明なBearer tokenだけを受け付ける。
- token自体の形式と90日期限だけでなく、KVに実在するsession、失効状態、canonical identity、アカウント削除状態を毎回確認する。
- 端末では`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`のKeychainへ保存する。
- サーバーではtokenのSHA-256 hashをキーにし、生tokenを保存しない。
- ログアウトはローカルtokenを先に削除し、push device登録解除とsession失効をbest effortで行う。
- 認証エラーを回避するためにtokenをクライアントだけで再発行しない。再認証によってWorkerにsessionを作る。

### 6.3 管理者とWebhook

- `/api/admin/*`はCloudflare AccessのJWTをWorker内でも検証する。
- 管理画面が同じoriginにあることだけを認可根拠にしない。
- RevenueCat webhookは専用shared secretで検証し、通常の利用者sessionとは分離する。
- 管理権限とWebhook secretに失敗した場合はfail closedとし、処理を継続しない。

### 6.4 パスワード認証への攻撃対策(クレデンシャルスタッフィング等)

メールとパスワードのログイン(`/api/auth/local/login`)と確認コードの送信・確認は、漏えいした認証情報の使い回しによる自動攻撃を想定して、次の層で守る。CAPTCHAは採用しない(効果に対して、手間・外部依存・有効化時の事故のリスクが見合わないと判断した。記録は履歴を参照)。

| 層 | 内容 | 実装 |
| --- | --- | --- |
| IPごとの回数制限 | Cloudflare Rate Limitingで、IPごとに回数を制限する | `rate-limit.js`、`wrangler.jsonc` |
| 複数キーの失敗回数 | アカウント、IP+アカウント、ASNを別々に数える。IPだけでは、分散した攻撃で効かないため | `login-throttle.js` |
| 段階的な待機 | 無料回数を超えると、待ち時間が倍々に増える(上限あり)。ロックはしない。待機中はパスワードを検証しない | `login-throttle.js` |
| 並行リクエスト対策 | 待機の確認と失敗の加算を、Durable Object内の1つの操作にする。検証の前に1回分を数え、正しければ戻す | `rate-counter.js` |
| 信頼済みの組 | 過去にログインに成功したIP+アカウントは、共有(アカウント・ASN)の待機を免除する。失敗は共有にも数える。14日で失効。攻撃者が失敗を重ねて持ち主を待たせることを防ぐ | `login-throttle.js` |
| 確認コードの制限 | メールごとに、送信は1時間5回、確認は1時間10回(成功も数える)。再送しても試行回数は戻らない。IPを分散した総当たりとメール爆撃を防ぐ | `app.js` |
| 漏えいパスワードの拒否 | 登録・再設定で、HIBPのk-匿名性API(SHA-1の先頭5文字だけ)で照合する。拒否しても確認コードは消費しない。アプリは、コード入力の画面で、新しいパスワードだけを入れ直させ、同じコードで続ける。障害時は照合を飛ばして受け付け、ログに残す | `pwned-passwords.js` |
| ユーザー列挙の防止 | 未登録・パスワード違い・壊れたレコードで、メッセージ・ステータス・処理量を揃える(PBKDF2とArgon2idを1回ずつ実行) | `local-auth.js` |
| ハッシュ | Argon2id(m=19MiB, t=2, p=1、OWASPの最小構成)。純JSの`@noble/hashes`。同時実行は2、待ちは32まで。満杯のログインは、ハッシュも照合もせずに503(`Retry-After: 2`)とし、試行は数えない。ただし、過去にそのアカウントへのログインに成功したIP(信頼済みの組)だけは、予備の16件まで受け付ける。パスワードを保存する操作(登録・再設定)は、確認コードを消費した後なので、満杯でも待つ | `local-auth.js` |
| 検知 | ログインの結果を、メール・IPを含めない構造化ログに出す。失敗(100件/時)・待機中の拒否(300件/時)・ハッシュ処理の混雑による拒否(50件/時)・履歴のあるアカウントへの未知の環境からの成功(10件/時)が閾値を超えたら、Slackへ1回通知する | `login-monitor.js` |
| 本人への通知 | 過去90日に使われていない「国+ASN」からのログイン成功で、本人にメールする。IPは載せない。1日3通まで | `login-monitor.js` |

運用上の性質は次の通り。

- **待機は、他人に起こされうる。** 攻撃者が標的のメールに失敗を重ねると、その人は新しい端末・回線から、最大15分の待機を受ける。ロックはしないので、待機は自動で解け、信頼済みのIPと、パスキー・Apple・Googleのサインインは影響を受けない。
- **確認コードの制限も同じ性質を持つ。** 他人が標的のメールの枠を使い切ると、その人の登録・再設定が最大1時間止まる。
- **国+ASNは粗い判定である。** 端末ごとの判定ではない。ログインの要求には端末の識別子がなく、モバイル回線やVPNで、通知が増えたり減ったりする。
- **履歴のない既存アカウント**は、機能の導入後の最初のログインで、1回だけ新しい環境の通知を受ける。休眠アカウントの乗っ取りを検知するためである。急増の集計には数えない。
- 保存する識別子(メールのhash、IPのhash)は、塩のないSHA-256である。メールは推測可能な識別子なので、これは「匿名化」ではなく「仮名化」として扱う。

Argon2idへの移行は、2段階でリリースする。詳しい手順と戻し方は`RUNBOOK.md`のRB-11を参照する。

## 7. 認可とテナント分離

- ユーザーID、room ID、document IDをrequest bodyから信用せず、検証済みsessionから主体を決定する。
- 友達、グループ、チャット、共同編集は、対象ごとにmember、owner、role、招待状態を確認する。
- KV key、Durable Object名、利用量キーには用途別domain separatorを付けたhashを使う。
- 一覧、検索、通知、エラー応答から他利用者の存在や識別子を不要に漏らさない。
- 複数identityのlink、アカウント削除、端末tokenの再所有は競合を想定し、直列化または冪等処理にする。
- テストでは「本人が成功する」だけでなく「別ユーザー、失効token、削除中account、別roomでは拒否される」を確認する。

## 8. 端末上の保護

### 8.1 Keychain

| 情報 | accessibility | 同期 |
| --- | --- | --- |
| Worker token、端末内ログインidentity | WhenUnlockedThisDeviceOnly | しない |
| 利用者が設定するAnthropic API key | WhenUnlockedThisDeviceOnly | しない |
| 保護ノートのAES-256鍵 | WhenUnlocked | iCloud Keychainで同期 |
| APNs device token | AfterFirstUnlockThisDeviceOnly | しない |

Keychain itemのserviceとaccountを固定し、tokenやkeyをUserDefaultsへ複製しない。

### 8.2 保護ノート

- 本文、描画、背景画像、OCR、カード用テキスト、要素画像をAES-GCMで暗号化する。
- 暗号化後はSwiftData上の平文フィールドを消去する。
- Face IDまたは端末passcodeの成功後にだけアプリが復号処理を呼ぶ。
- 鍵はiCloud Keychain同期のためbiometry-boundではない。生体認証はアプリ側の手続き上のgateであり、鍵自体へのSecure Enclave制約ではない。
- 保護設定時は既存の平文自動backupを削除し、保護中は平文backupを作らない。

この機能を「端末やApple IDが侵害されても読めないゼロ知識暗号」と説明してはならない。

### 8.3 ファイルと一時データ

- importしたファイル名、PDF、画像、生成物には個人情報が含まれる前提で扱う。
- temporary/cache上の生成物は用途終了後に削除し、共有先へ渡した後の管理は利用者へ明示する。
- 自動backupは平文JSONを含む。OSのData Protectionに依存するだけで、保護ノート相当の暗号化ではない。
- アカウント削除ではSwiftDataだけでなくApplication Support、Documents、Caches、temporary、共有添付の残存も確認する。

## 9. 通信、入力、出力

- 本番endpointはHTTPSだけを許可し、URLにusername、passwordを含めない。
- JSON、text、画像、添付、MCP requestには実bytesでの上限を設ける。`Content-Length`だけを信用しない。
- 文字数、配列件数、Base64 decode後size、MIME type、URL schemeを境界で検証する。
- JSON応答には原則`no-store`、`nosniff`、`frame-ancestors 'none'`、`no-referrer`を付ける。
- エラー応答にstack trace、secret、存在確認に不要な内部ID、上流providerの機密情報を含めない。
- Rate Limitは認証、Passkey、チャット、AI、MCP、報告、Webhookごとに目的に合う単位で設定する。
- retryは冪等性を確認し、課金、送信、取り込み、削除で重複作用を起こさない。

## 10. AI機能のプライバシー

### 10.1 送信される内容

AI機能では、操作に応じて次の情報が端末外へ出る。

- AIトークの質問、会話履歴、明示的に選択した資料の文脈
- 問題文、答案文、切り抜き画像または写真
- 翌日復習の元になった質問と文脈
- 選択した添付資料の内容

回答生成の提供先はOpenAIのみとする。アプリと公開APIでLuna/Terra/Sol/Astraに制限し、旧Google同意では送信しない。openai-v1と13歳以上の年齢区分確認（teenは保護者同意）が必要。開いているノートは自動添付しない。

### 10.2 必須要件

- 初回利用前に、何を、誰へ、何のために送るかを利用者が確認できるようにする。
- 設定から同じ説明へいつでも戻れるようにする。
- 画像は長辺を制限し、最大枚数とrequest sizeを制限する。
- AIへのsystem instructionと利用者コンテンツを区切り、prompt delimiterを無害化する。
- AI出力は信頼せず、JSON schema、型、文字数を検証してから保存・表示する。
- AI要求本文、画像、API keyをアプリログ、Workerログ、エラーreportへ記録しない。
- provider、model、送信項目を増やす変更では、アプリ内開示、プライバシーポリシー、App Store申告を同時に更新する。

同意は`google-v2`として端末に保存し、APIヘッダーにも付与する。旧booleanの確認済み状態は同意とみなさない。取消し時に翌日復習も停止する。`AI_PROVIDER_APPROVED`は既定falseで、対象年齢・訓練利用・保持条件の承認がない限り送信を拒否する。

## 11. MCP連携

- 外部clientはOAuth 2.0 Authorization Code + PKCEで接続する。
- redirect URIは事前登録値と完全一致させる。HTTPSを原則とし、HTTPはlocalhostだけに限定する。
- pairing codeは12文字、認可待ちは10分、authorization codeは5分、access tokenは1時間、refresh tokenは90日とする。
- scopeは`studiquo.read`と`studiquo.write`を分け、各toolで必要scopeを検証する。
- iOSが明示的に同期したsnapshotだけをread対象とし、CloudKitや端末DBへ直接アクセスさせない。
- writeは`MCP_INBOX`へ入れ、iOSが検証・取り込みする。外部clientからSwiftDataへ直接書かない。
- authorization codeとrefresh tokenは一度だけ消費できるようにする。
- 利用者は接続client名とscopeを確認し、後から接続を取消せるようにする。
- snapshotにはノートOCR、文書、予定などConfidential情報が含まれる。接続許可を一般的なログイン同意と混同しない。

## 12. ログ、診断、問題報告

### 12.1 通常ログ

ログへ出してよいのは、request ID、処理種別、結果、status、時間、個人を直接示さない集計値を基本とする。
次をログへ出してはならない。

- password、確認コード、session・OAuth・APNs token、API key、secret
- メールアドレス、外部subject、友達コードの生値
- ノート、OCR、チャット、AI prompt、答案、カレンダー本文
- 添付内容、ファイルpath、利用者が入力したエラー文
- Authorization header、Webhook payload全体

ログインの結果ログ(`event=local_login`)は、結果・国・ASN・初めての環境かどうかだけを出し、メールとIPを含めない。漏えいパスワードの照合を飛ばしたときのログにも、パスワードとhashを含めない。

必要な相関にはtokenやidentityの用途別hashを使い、hashであっても個人関連データとして扱う。

### 12.2 自動エラー診断

- 既定OFF。利用者が明示的にONにしたときだけ収集・送信する。旧設定は新しい許可へ移行しない。
- OFFの場合は新規収集を止め、端末上の未送信queueを削除する。
- 送信内容はkind、安定したsignature、短いtitle、限定した技術detail、発生数、時刻、アプリ・OS・端末modelに限定する。
- 既知のNSErrorはdomainとcodeだけを使い、messageを送らない。
- crash stackはsymbol、offset等へ制限し、ノートやチャット本文を構築元にしない。
- D1では同じfingerprintを集約し、accountとの関連は用途別hashにする。アカウント削除時に関連行を除去する。

### 12.3 手動の問題報告

- 説明文は必須、スクリーンショットは既定OFFの明示的opt-inとする。
- 送信前に画像をpreviewし、ノートやチャットが映り得ることを表示する。
- JPEG/PNGだけを許可し、decode後3 MB以下、本文2,000文字以下に制限する。
- screenshotの取得はWorkerでCloudflare Access JWTを検証する。Slackには本文・画像を送らない。
- KVは90日TTL、D1は定期ジョブで削除し、管理一覧は期限超過を非表示にする。過去のSlack投稿は自動回収できず、運営による整理が必要。

## 13. Push通知

- device tokenはPersonal情報として扱い、account間で再利用された場合は以前の所有者から外す。
- 利用者のcategory別設定を尊重する。
- APNs payloadへsecretや完全な学習内容を入れない。
- チャット通知は現在本文previewを最大120文字含むため、ロック画面で第三者に見える可能性がある。将来、preview非表示設定を検討する。
- 通知tapのrouteとIDは入力として検証し、通知だけを認可根拠にしない。

## 14. Secret管理

Workerで扱うsecretには、AI provider key、APNs key、Resend key、RevenueCat webhook secret、Slack webhook URL、Cloudflare Access検証値などがある。

- secretは`wrangler secret`等のsecret storeで管理し、`wrangler.jsonc`のvarsやGitへ入れない。
- iOSへ埋め込めるのは公開client設定だけであり、サーバー権限を持つkeyを含めない。
- ローカル開発は個別の開発用secretとnamespaceを使う。本番値をテストへ流用しない。
- 漏えいが疑われたら、削除だけでなくrotation、失効、利用履歴確認、影響範囲評価を行う。
- secret名、管理者、利用箇所、rotation手順、最終rotation日を非公開台帳で管理する。

## 15. 保持とアカウント削除

### 15.1 保持方針

各保存データには次を定義する。

1. 収集目的
2. 正本となる保存先
3. 通常の保持期間
4. account削除時の動作
5. backup・replica・外部processorから消えるまでの期間
6. 法令、会計、不正対策等で残す場合の根拠とaccess制限

期間未定のデータを新規に追加してはならない。既存の未定義項目は「19. 既知の課題」で管理する。

### 15.2 現行のアカウント削除

Workerは削除状態を`deleting`として先に記録し、途中失敗後も再実行できるcheckpoint方式を使う。削除中accountのsessionは受け付けない。

現在、主に次を削除または無効化する。

- 全session、snapshot、action、認証account、identity link、Passkey情報
- MCP grant、access・refresh token、inbox
- 友達・グループ参照、chat profile、code、avatar、device token
- D1の利用イベント、初回利用日、エラーとaccountの関連
- メールのhashで名づけた`RATE_COUNTER`のデータ: ログイン元の履歴(国+ASN)、アカウント単位のログイン失敗、ログイン通知の枠、コード送信・確認の試行回数。メールの確認コードの記録(`email-verify:`)も含む
- iOSの全SwiftData model、UserDefaultsのaccount関連設定、認証Keychain item
- D1の問題報告・購読者情報・購入イベント、KVの報告画像
- Documents、Caches、一時ファイル、自動バックアップ、共有Inbox内のアプリ管理コピー（外部の原本は削除しない）

次のものは、退会時に消せない。

| データ | 残る期間 | 理由と内容 |
| --- | --- | --- |
| パスワードの世代カウンタ(メールのhash+整数) | 退会後7日。同じメールで再登録すると、自動削除の予約が取り消され、保持に戻る | 退会より前に始まったPBKDF2→Argon2idの書き換えが、削除済みのパスワードのhashを書き戻さないようにするため。KVの古い読み取りは最大約1分なので、7日は十分な余裕である |
| IP+メールのhashで名づけた失敗回数・信頼済みの記録 | 最大約14日+1時間 | IPを列挙できないため、削除できない。それぞれの有効期限で消える |
| 退会と同時に進行中のログインが作る、ログイン元の履歴 | 最大90日 | 退会の最中のログインが履歴を作り直す、まれな競合 |

世代の退役は、アカウント本体を消す前に行う。メールに紐づくその他のデータの削除は、本体を消した後に行う。前者に失敗すると退会は先へ進まず、後者に失敗しても、本体はすでに消えていて、毎時の再試行で残りが完了する。

他利用者側の会話を壊さないため、過去メッセージは「削除済みユーザー」として匿名化され得る。App Storeの購読はApple側で別途解約が必要である。

サーバーが永続削除ジョブを受理したら202を返す。サーバー内／外部削除には待ち時間があり、完了前に成功したと断定しない。端末削除失敗は永続マーカーを残し、次回起動で再試行画面を出す。外部顧客削除待ちのidentityは再ログインを拒否する。

## 16. 外部サービス変更時の確認

Apple、Google、Cloudflare、iCloud、RevenueCat、Resend、Gemini、Anthropic、OpenAI、APNs、Slackなどを追加・変更するときは、次を記録する。

- 送るデータと目的
- 保存地域、保持期間、再委託、モデル訓練への利用有無
- DPA、利用規約、プライバシー条件
- account削除・開示請求の連携方法
- 障害、quota超過、契約終了時の挙動
- API keyの権限とrotation
- 利用者への説明と同意の要否

外部サービスの現在の条件は変わり得るため、release前と年次に公式情報を再確認する。

## 17. セキュア開発要件

セキュリティまたは個人情報へ影響する変更は、`AGENTS.md`のfullモードと`docs/DEVELOPMENT_WORKFLOW.md`を適用する。

実装前に最低限、次を決める。

- 保護対象と攻撃者
- 信頼境界と権限主体
- 収集・送信・保存・削除されるデータ
- misuse、replay、IDOR、tenant混同、prompt injection、過大入力、競合の失敗形
- backward compatibilityとrollback
- 利用者向け説明への影響

実装時は次を守る。

- 最小権限、deny by default、fail closed
- 入力上限とserver-side validation
- secretとpersonal dataを含まないログ
- migrationは追加型で、既存fileを書き換えない
- appとWorkerを同時にreleaseできない前提の互換性
- security controlを無効化するfeature flagを常用しない

## 18. 検証要件

変更に応じて、次を自動テストまたは手動検証する。

- 正常なlogin、期限切れ、失効、偽造token、削除中account
- Apple・Google token検証、メールcodeの期限・試行回数、Passkey challenge replay
- 別account、別room、別document、別MCP clientからのaccess拒否
- OAuthのPKCE、redirect URI、state、scope、codeとrefresh tokenの一回消費
- request body、文字数、配列、画像、添付の上限
- chat、共同編集、account統合、削除の並行実行
- account削除後にsession、snapshot、MCP、push、友達参照、利用関連が残らないこと
- 自動診断OFF時に収集・送信・queueが残らないこと
- secret、token、本文がログ・エラー応答・test outputへ出ないこと
- AI provider選択とアプリ内開示が一致すること
- Privacy Manifest、App Store申告、利用者向けprivacy policyが実装と一致すること

検証結果には、実行command、結果、未実施項目、環境制約を記録する。

## 19. 既知の課題と優先対応

### P0: 公開前に判断が必要

1. Privacy Manifestにデータ分類を追加したが、App Store Connect申告・責任者照合は未実施。
2. Google一社に制限し、同意・承認gateを実装した。学生・未成年者への提供可否、契約、訓練利用・保存条件の承認は未完了。承認までAIは停止する。
3. D1/KV削除・90日/180日保持・RevenueCat削除ジョブを実装した。本番migration・secret設定・定期処理有効化・監視は未実施。詳細は`PRIVACY_RELEASE_CHECKLIST.md`。
4. 再登録時の課金顧客世代管理、Apple認可取消し、共同編集データ削除範囲を公開前に確定する。

### P1: 早期に修正する

5. 端末管理ファイルの消去と再試行を実装。CloudKit同期削除・App Group共有Inboxは実機でも確認する。
6. 旧Slack投稿と所有者を復元できない旧問題報告の処理は別途運営対応が必要。
7. `StudiquoApp.swift`の一部起動ログは`String(describing: error)`をpublic privacyで記録する。pathや利用者由来文字列が混ざらない形式へ限定する。
8. `PrivacyPolicyView`と`mcp-server/src/legal.js`は手作業で重複管理されている。単一sourceから生成するか、同一性testを強化する。

### P1(追加): パスワード認証まわり

- Argon2idの待ち行列(同時2、待ち最大32、信頼済みの組の予備16)は、Workerのインスタンスごと。偽のメールで待ち行列を埋めると、そのインスタンスで、新しい端末・回線からのログインが503になる(既知の端末は予備枠で通る)。IPごとの同時実行の制限は、共有IP(学校など)の正規の学生が429になる副作用に対して効果が小さいので、採用していない。攻撃者が、自分の無料アカウントで多数のIPを信頼済みにすると、予備枠を埋められる(通常の枠だけの状態に戻るだけ)。
- 確認コードの送信・確認の429は、サーバーが待ち時間(`Retry-After`)を返さないので、アプリは時間を言わずに「しばらく待ってから」と案内する。メール単位の制限は最長1時間、IPごとの制限は1分と、原因で長さが違う。サーバーが残り時間を返すようにすれば、アプリは自動でその時間を表示する。
- 応答時間の均一化、通知メールとSlackの実送信、`ARGON2_WRITE=true`の本番相当の環境での確認は未実施。
- 保存する識別子の塩なしSHA-256は、メール・IPの推測に弱い。サーバー秘密鍵によるHMACへ、横断的に移行することを検討する。
- Argon2id移行後に、PBKDF2のレコードが残らなくなったら、`local-auth.js`のPBKDF2のダミー計算と旧レコードの分岐を外す。
- App Attest(端末とアプリの証明)の導入を、CAPTCHAに代わる強い対策として検討する。

- ログインに成功する経路が、KVの遅さのために、約3〜6秒かかる(ステージングの実測。失敗の経路は約0.9秒)。`linkVerifiedEmail`の無駄な書き込みは減らした。残る主な原因は、`mintSession`のKVの操作を、順番に3回行っていること(最初の2つの読み取りは、並列にできる)と、KVの読み取りそのものの遅延。Apple・Google・メールのすべてのサインインが通る処理で、本番の現行コードにも、同じ遅さがある可能性が高い。

- メール(確認コード・新しい環境の通知)の送信元が、`RESEND_FROM_EMAIL`未設定のとき、Resendの共通の送信元(`onboarding@resend.dev`)になる。この送信元は、Resendのアカウントの持ち主のアドレスにだけ配送できる(ステージングで、`example.com`宛が422になった)。本番に、`RESEND_FROM_EMAIL`が設定されているかは、CLIからは確認できていない(ダッシュボードで確認する)。本番の前に、Resendで自分のドメインを認証し、そのドメインのアドレスを設定する。

### P2: 設計改善

9. `wrangler.jsonc`の開発用`preview_id`が本番KV namespaceと共通である。dev・staging・productionを分離する。
10. チャットpushが本文previewをロック画面へ表示する。利用者がpreviewを隠せる設定を検討する。
11. 保持期間と削除対象を機械可読な台帳にし、定期purgeと削除testへ接続する。
12. 年齢確認がなく、学生利用を想定している。対象年齢、保護者同意、ストア上の年齢区分、未成年者dataの扱いをproduct・legalとして決定する。

課題を解消したら、コードとtestの参照を残してこの節を更新する。

## 20. インシデント対応

漏えい、誤送信、不正access、secret流出が疑われる場合は次の順で対応する。

1. 事実と時刻を保存し、個人情報を含む追加ログ採取は最小限にする。
2. 影響を広げる処理を止め、token・secretの失効、feature停止、access制限を行う。
3. 対象データ、利用者、期間、外部service、backupを特定する。
4. 修正と再発防止testを作成し、独立したsecurity reviewを受ける。
5. 法令、契約、App Store、利用者通知の期限と要否を責任者が判断する。
6. postmortemに原因、検知、影響、復旧、恒久対応、owner、期限を残す。

証拠を消す可能性があるため、調査前に広範なログ削除やDB書き換えを行わない。

## 21. 変更時チェックリスト

- [ ] 扱うデータと分類を記載した
- [ ] 収集目的、保存先、外部送信先、保持期間、削除方法を決めた
- [ ] 認証主体と対象resourceの認可をserver側で確認した
- [ ] 入力size、件数、形式、rateを制限した
- [ ] ログとエラー応答にsecret・personal data・contentが出ない
- [ ] account削除、接続解除、opt-outに新しいデータを含めた
- [ ] retry、並行実行、途中失敗、replayを検証した
- [ ] 利用者向け開示、privacy policy、App Store申告を更新した
- [ ] migration、旧app、旧Worker、rollbackを確認した
- [ ] 関連するunit、integration、negative testを追加した
- [ ] security/privacy観点の独立レビューを受けた
- [ ] release後の監視とincident ownerを決めた

## 22. 実装上の参照先

- `docs/ARCHITECTURE.md`: システム構成と主要データフロー
- `AGENTS.md`: リポジトリ共通ルールと開発モード
- `docs/DEVELOPMENT_WORKFLOW.md`: fullモードの詳細手順
- `studiquo/PrivacyInfo.xcprivacy`: Apple Privacy Manifest
- `studiquo/Views/ContentView.swift`: AI開示、privacy policy、MCP token、account削除UI
- `studiquo/Services/AuthenticationStore.swift`: 端末認証状態とaccount削除workflow
- `studiquo/Services/NotebookEncryptionService.swift`: 保護ノートの暗号化とkey管理
- `studiquo/Services/ErrorReportService.swift`: 自動診断のopt-out、queue、送信内容
- `studiquo/Services/DiagnosticReportBuilder.swift`: MetricKit診断の最小化
- `studiquo/Services/NotebookBackupService.swift`: 自動backupと保護ノートの扱い
- `mcp-server/src/session.js`: sessionの実在確認とcanonical identity
- `mcp-server/src/local-auth.js`: パスワードのhash(Argon2id、PBKDF2からの移行、世代による競合対策)
- `mcp-server/src/login-throttle.js`: ログイン失敗の多段制限と待機
- `mcp-server/src/login-monitor.js`: ログイン結果のログ、Slackアラート、新しい環境の通知
- `mcp-server/src/pwned-passwords.js`: 漏えいパスワードの照合(HIBP)
- `mcp-server/src/rate-counter.js`: 回数制限・失敗回数・履歴・世代を保持するDurable Object
- `mcp-server/src/account-deletion.js`: server側account削除
- `mcp-server/src/mcp-oauth.js`: MCP OAuth、PKCE、token期限
- `mcp-server/src/ai.js`: AI provider、quota、入力処理
- `mcp-server/src/issue-reports.js`: 問題報告、screenshot、90日TTL
- `mcp-server/src/app-errors.js`: 自動診断の集約
- `mcp-server/src/http.js`: body上限readerとsecurity headers
- `mcp-server/src/legal.js`: 公開privacy policy

## RAG自動登録のサーバー安全基盤（2026-10-11・ローカルのみ）

新同意・資料資格・世代を`rag/control.js`、本文取得・送信の資格検証を`rag/authorization.js`に分離した。既存realSessionのcanonical userからaccountKeyを生成する。bodyのaccount IDやfolder IDを権限と扱わず、Vectorize account事前filterとD1 owner条件を維持する。

同意epochとdocument generationはCASで更新する。locked/excluded/trashed/deletedは通常uploadでは解除できない。source IDを変えるだけでも管理情報なしでは登録できない。document IDそのものの所有権を証明する機能ではなく、本人のローカルPDFの申告管理に限定する。共有資料のサーバーACLは別途必要。

D1の全登録guard、Embedding直前、検索・neighbor・rerank直前、context最終組立、OpenAIの各再試行直前で資格を確認する。出典と使用neighbor全体は単一SQL snapshotで照合し、失効・障害時は本文・出典を捨てて通常チャットへ戻る。本文・質問・title・Embedding入力・promptを新しいログへ出さない。

物理削除失敗時は検索を先に拒否し、jobを残して既存の毎時cronとowner用cleanup APIで再試行する。旧writerのvector補償はID単位であり、成功した新writerの資料を失効させない。Worker強制終了の未確定writeは自動解決しないため、account削除完了と扱わない。本番前に監視・運用手順と実Vectorize mutationの順序を確認する。外部送信開始後の撤回で送信済み本文を回収できるとは約束しない。厳密な同時送信・撤回の直列化も今回の保証外。

まだiPad自動送信は有効でない。公開前に、新しい包括同意UI、既存/将来PDFの対象範囲、保存と外部送信、停止と検索撤回と物理削除の違い、未確定削除の表示をプライバシーポリシーとアプリで説明する。既存rag-v1同意を包括同意として読み替えない。オフライン未同期ロック、複数端末、共有資料の保証は別段階。

## 自動PDF索引の同意と停止（ローカル実装、未公開）

従来の手動RAG consentから自動許可を推定しない。対象は現端末のPDF全体またはフォルダ、将来追加PDFは既定対象外。新UIで本文/OCR/タイトル/ページ番号のCloudflare保存と関連抜粋のOpenAI送信、以前のaccountで保存した資料の混在可能性、初回managed移行時の旧手動index失効を示す。locked/暗号化/ゴミ箱を抽出前と各await後に再検査し、通常の手書きNotebookは自動対象外。

ロック・除外・削除・同意撤回は同期的に端末の資格を失効させ、別制御taskでサーバーへ反映する。通信不能中は検索を止める。別端末のlock/trashを古い未ロック端末が自動解除することを防ぎ、個別明示再許可だけ復元する。owner/Worker endpoint変更後の応答を採用しない。serverはBearer realSessionによるcanonical ownerで認可する。保存queueは本文なしmetadataのみ。

公開プライバシーポリシー、ストア申告、実機同意画面とデータ削除運用の確認は公開前の残件。送信済みcontextは回収不可、オフライン別端末の操作はサーバーへ到達するまで即時失効できない。共有資料ACL、multi-device競合、未確定Vectorize writer journal解消は本番有効化前の別工程。

### OpenAI/RAG統合の安全境界（2026-10-13、未公開）

RAGの旧rag-v1はGemini送信の説明だったため、新しいrag-openai-v1を要求する。自動索引stateにprovider同意版を保存し、旧stateの自動再開を防ぐ。Cloudflare保存・OpenAI回答用抜粋送信の双方を明示する。OpenAI Responsesのinstructionsは各attempt直前のD1再認可結果から作る。store:falseは応答の後日取得用保存を無効にする設定であり、すべての保持や訓練利用の契約保証と同一視しない。本文、AI prompt、embedding入力、provider error本文はログへ出さない。AI同意・年齢確認・canonicalユーザー境界は公開APIで確認する。RAG disabled時は通常OpenAI経路を維持する。flagsはfalse、既存RAG migrationの改名・適用はしない。

独立レビューとローカル回帰検証は完了（Worker1,184・iOS unit1,624・RAG UI3件成功）。旧提供先同意の新提供先への流用を拒否する。hashed利用量counterの40日窓は40日以内の物理削除保証ではなく、窓終了後同長のalarmで回収予定（初回takeから約80日後）。保持説明と即時削除対象の確認は公開前に残る。


## iPadの構造索引・出典接続（2026-10-17、ローカル実装）

原PDFのbytes hashでprepared Docling packageを検証し、新Notebookへ取り込む経路を実装。packageはNotebookのoptional属性に保持し、既存ロック暗号化に含める。編集時は失効し、manual/managed索引は現在の内容を使用する。Worker capabilityを確認し、構造batchを再分割せず送信する。出典metadataは会話保存と安全な補助表示へ接続し、source/page認可を維持する。精密bboxジャンプと原PDFの自動サーバー解析は未接続。iOS関連98成功・最終関連36成功（重複）、Worker1723成功。実機・iCloud移行・実資料精度の証明ではない。詳細: [RAG_IPAD_STRUCTURED_INTEGRATION.md](RAG_IPAD_STRUCTURED_INTEGRATION.md)。公開操作なし、自動スケジュールPAUSED。


## Doclingのprivate Container実行境界（2026-10-17、未配備）

独立services/docling-workerにprivate RPC/default flag false、単発jobの期限・取消・非本文状態・destroy後返却を実装。Container専用Python入口、ready前版/model検証、有限no-follow orphan cleanup、offline/nonroot Docker recipeとsample configを追加。既存MCP/iPadは未接続。JS28・Python関連60/既存49成功、型生成/bundleと合成2pageの実Nodefetch→Docling接続を確認（VMlifecycleはmock）。Docker不在でLinux build/実Cloudflare起動・隔離・停止は未検証。原PDF別同意/認可/admission・削除/予算・運用監視と依存監査を満たす前に有効化しない。DO stateはopaque ID/status/deadline/cleanup回数のみで本文なし、tombstone retentionは未設計。storage障害でpoison/alarm保存できない場合は運用停止確認が必要。詳細 [RAG_DOCLING_CONTAINER_BOUNDARY_REPORT.md](RAG_DOCLING_CONTAINER_BOUNDARY_REPORT.md)。公開操作・追加購入なし、自動スケジュールPAUSED。

## 原PDFの永続同意と文書認可（2026-10-18、内部未接続）

原PDF同意をテキストRAG同意と分け、現在のRAG epochへbindする内部CASを追加。既存RAG同意・account削除のDB triggerで失効させる。信頼済み認証session由来のcanonical ownerと文書ID/source ID/generation/抽出text hash/両同意epochを単一SQLで確認する。任意のclient account keyは受け取らず、欠落と他人の文書は同じ拒否。本文受信前のheader確認だけでは認可にしない。schema/DB障害は閉じ、内部SQL例外を固定エラーへ置き換える。

今回の確認はSQL時点のsnapshotであり処理leaseや利用量予約ではない。原PDF bytesのdigest binding、新規Notebook用intake登録、admission/費用予約・job取消削除と送信/結果採用時再確認は未接続。公開route/アプリ同意UI/法務文言の確定や外部送信を実施したものではない。新0010は未適用、公開前の実D1競合・削除・旧新Workerの運用確認が必要。

## 新規PDF受付とraw digest検証（2026-10-18、内部未接続）

新規Notebookには解析前text sourceHashがないため、0011のintake専用generation/UUIDを使う。付与時と再確認時のSQLでcanonical owner、両同意epoch、期限、未取消、既存rag_documents不在を確認。原PDFの実bytesは有限reader後に内部verifierへ渡す契約で、非同期前にコピーし長さ・signature・SHA256と検証後の再認可を行う。raw SHA256は既存抽出text hashと別。本文・PDFをDB/ログへ保存しない。取消・親失効はdigest/長さも消すが、期限切れの自動物理削除は未実装。

verifierはadmission/job claimではなく同時成功を排除しない。返却bytesを可変の恒久許可とせず、将来の送信前・結果採用前にも再確認する。受信前の利用枠/並列メモリ予約・once-only処理/費用台帳・取消と実行停止の連携・記録保持上限が整うまでbody reader/公開route/Doclingには接続しない。実D1競合・trigger連鎖の運用検証とiPad/結果採用は未実施。

## 原PDF jobの受信権と停止確認（2026-10-18、内部未接続）

受付の同一再送にjob IDを返しても、本文を受信できるのは一度限りreceive claim勝者だけという契約を追加。execution tokenは一度だけ返しDBはhashのみ、一般status応答へ含めない。dispatchも同tokenの単一CAS、DB書込み時点でintake/本人/両同意/期限を再確認する。cancel/失効/期限は停止要求だけとし、停止不明の枠/予約を自動解放しない。停止確認・policyはclient入力として受け付けず、信頼済みexecutor/server設定のみから作る。

64MiB/件のmemory weightと最大96MiBの設定上限は保守的な内部会計制限で、全経路heap計測やOS強制制限の証明ではない。費用unitsも実金額の上限保証ではない。token受領前に応答を失うと枠が保持され得るため、実行停止の証拠に基づく復旧が必要。未接続unitのためreader/VM停止/本番費用制御の完成とはしない。intake作成APIそのもののrate/行数制限、jobの監視/cleanup再試行・retention、実D1競合を公開前に整備する。

2026-10-18 原PDFの内部受信/解析orchestratorを追加。DB/RPC待機のtimeoutと実task終了を区別し、reader・検証・consumerが未終了なら枠を保持する。cleanup graceは全経路共通。大manifestは非公開trusted consumerへ枠保持中にだけ渡し、参照解放後に精算する。正式採用/公開は別再認可・commitが必要。合成2pageの実offline Docling/loopback接続は成功、VM lifecycleはshimで、実Linux/CloudflareのOS隔離確認ではない。詳細: [接続記録](RAG_PDF_ORCHESTRATION_REPORT.md)。

2026-10-18 停止再試行の内部reaperと集計を追加。停止RPCは2秒待機、最大3回、30秒leaseのCAS勝者だけ実行。timeoutで実RPCが消えるとは扱わず、遅い結果から精算しない。未claimだけ0精算、claimedはremote停止確認後も保留し、ローカル処理終了の証拠がない状態で枠を解放しない。flags off/削除後も停止できる一方、公開route/一般クライアントへ接続しない。新台帳はjob IDと固定運用metadataのみ、監視応答も集計値だけ。token紛失時の自動回収・retentionは残件。詳細: [停止と復旧](RAG_PDF_RECOVERY.md)。

## 2026-10-18 実Linux・公開HTTP接続（最新）

実Linux amd64コンテナで合成2ページを解析（22.908秒）、通信遮断・UID10001・非書込コード/モデル・取消・期限切れ・SIGTERM・job削除を確認。認証済みローカルworkerd→private RPC→同Linux Docling→最終complete/精算も21.045秒で成功した。Cloudflareへの配備・remote migration・公開URL有効化は未実施で、ローカル成功をremote完了とは扱わない。

公開HTTP handlerは認証後に同意/intake/process/cancelを処理する。受信前認可・予約、転送中の再認可、停止精算後のcompleteを維持。早すぎるResponse返却によるworkerdの入力破棄、isolated Pythonの兄弟import、WranglerのCASE分割を実環境で修正。受付/cleanup/private実行flagsはfalse。本番private bindingなし。staging設定とdry-runを準備済み。

検証: サーバー全1,851件、processor61件、provision6件、HTTP/app/process42件成功。Python102依存のauditは既知脆弱性0・skip0（OS/モデルライセンスの保証ではない）。独立Code/Securityレビューの未解決所見なし。回答品質の有料評価・実資料・未使用20問は使っていない。

詳細・制約・ロールバック: [実Linuxと公開接続の検証](RAG_LINUX_PUBLIC_CONNECTION_REPORT.md)。次はstagingの既存配備/DB状態と利用条件を確認し、remote配備の承認範囲を確定してから段階適用・疎通する。iPad正式採用、claimed停止不明の復旧、retentionは残る。

## 2026-10-19 原PDF記録の保存・削除設計（未実装）

[保存期間・整理順](RAG_PDF_RETENTION_DESIGN.md)を追加。期限切れintakeは永続取消/詳細削減、停止不明jobは保持、精算済み詳細は暫定48時間＋過去UTC窓＋参照なしでのみ整理候補とする。世代/失効fenceと現DO spent markerは単純削除しない。settled_at/単調会計floor/原子的削除/旧writer互換が追加実装の前提。account削除callerのPDF停止pending接続、将来receiptと期限付きv2 RPC/DO purgeは残る。これは稼働中の保持保証ではなく設計で、実データ削除・設定変更は行っていない。

## 原PDF Step5-Aのローカル実装（2026-10-19）

追加0014にnullable精算時刻/control/index。旧schema停止互換、旧時刻NULL保持。内部期限整理はflag/schema gate下で最大10受付を永続取消し、PDF指紋/長さ/requestを削減、世代fenceと停止不明job/利用枠を維持する。非識別集計のみ、scheduler/公開接続なし。物理job/DO削除・account PDF pending・receiptは未完。最終server1865件＋実local D1成功、独立レビュー指摘修正済み。remote未適用。詳細: [Step5-A報告](RAG_PDF_RETENTION_IMPLEMENTATION_REPORT.md)。

## 原PDF Step5-Bの処理済み台帳整理（2026-10-19）

追加0015で初期無効の内部purgeを実装。精算から48h・過去UTC窓・永続失効/置換・既知時刻・復旧done/leaseなしだけ、粗い候補10件とcursorで有限整理。floor/child/parent/leaseは原子的rollback、writer fenceは停止後も維持。legacy/停止不明/registry参照は保持、将来採用migrationはpre-adoption契約を先に変更して旧purgeを閉じる。server1888件と実local D1同時pass/rollback検証成功。remote未適用、HTTP/cron/flag未有効化。詳細: [Step5-B報告](RAG_PDF_PURGE_IMPLEMENTATION_REPORT.md)。


## Step6-A停止証拠基盤（2026-10-19）

停止済みVMの応答とサーバー内task/reader cleanupの終了を分離した停止証拠基盤を追加。両者が同じclaimへ永続化した場合だけtokenなし精算を許可する。証拠保存前のexecutor消失は枠を保持する。本処理/reaperには未接続、既存legacyは自動復旧しない。証拠tableの本文/digest/raw token保存はない。

詳細: [停止証拠の設計](RAG_PDF_STOP_EVIDENCE_DESIGN.md)。


## Step6-B停止証拠の実処理接続（2026-10-19）

実PDF処理のtask/reader cleanup/monitor終了と参照解放を停止証拠へ接続し、保存済み両証拠に限りreaperがtokenなし精算する。精算UPDATEでもliveleaseを再検査し、証拠前のexecutor消失は枠保持。同一cleanup cancelは一回。0017は親行消失後のFK cascadeでのみ証拠を整理できる条件を追加し、手動contextだけの単独消去を拒否する。独立Code/Securityの指摘を修正し再レビュー済み。新flag・公開/cronは未有効。

詳細: [Step6-B報告](RAG_PDF_STOP_INTEGRATION_REPORT.md)。


## Step5-Cアカウント削除とPDF後片付け（2026-10-20）

account削除はPDFの停止証拠が不足しても他の独立消去を続け、最終deletedだけ保留する。token/hash/メール/device関連keyは独立phase終了時にcheckpointから落とし、必要なidentity対応と固定PDF状態のみ保持。owner専用reaperは64lowerhex必須でnull/undefinedによるglobal化を拒否し、flags offでもcleanup可能。schema不明や証拠不足を削除完了にしない。

詳細: [Step5-C報告](RAG_PDF_ACCOUNT_CLEANUP_REPORT.md)。


## Step5-D1 private v2期限境界（2026-10-20）

D1ではprivate入口/DO双方のv2専用モードで旧parse/cancelと旧引数helperを拒否、期限固定・実bytes digest・期限後停止を検証。期限後の空DOでもVM destroy確認が必須でmarkerを新設しない。旧stateへ期限を創作せず保持する。MCP caller移行/finite purgeは未実装で、flagは未設定。

詳細: [D1結果](RAG_DO_V2_BOUNDARY_REPORT.md)。


## Step5-D2a v2接続（2026-10-20）

MCPの解析/取消/証拠/reaper/account cleanupを固定v2期限へ接続。dispatch CASと同時にjobへPDF-linkable digestと元notAfterを保存し、取消時にintake情報から復元しない。保存済v2はflags OFFでもv2で停止し、失敗時に旧RPCへfallbackしない。旧pendingは保存deadlineだけでv2取消へdrain可能だがparse契約を後付けしない。新job側digestは取消/account削除後も停止不明/未精算中、およびpurge無効中は残る。既存48h等の条件付き親job purge時にだけ削除。PDF本文/生tokenの永続保存やログ出力はない。remote ackでlocal停止を代用しない。実local RPC/DOは合成VM IOで検証、実VM停止/公開適用は未確認。

詳細: [接続検証](RAG_PDF_RPC_V2_INTEGRATION_REPORT.md)。


## D2b-A：停止観測と削除前提（2026-10-20）

private v2のdestroy解決後に固定の停止観測時刻を保存し、保存/clock/alarm失敗やtimeoutは成功ackを返さない。PDF/digest/tokenはDOへ追加保存しない。過去の観測は全task静止/現在停止/削除許可の証明ではなく、失敗後もpoison状態で保持する。全消去後のclock後退で再送が実行可能になる反例から物理削除を保留。再実行防止の外部fence等・clock契約が必要。実Linux停止は再確認、Cloudflare実VMは未確認。


## D2b-B：再実行防止の設計（2026-10-20）

DO全消去後の再実行防止は、最小marker保持を既定とし、既存D1で一回だけ許可を消費するCASを第一候補に設計した。privateへADMIN_DB全権を渡さず、専用namedRPCの固定操作だけを予定。許可遅延/元task静止/現在同意/clock/backup復旧の条件が未成立ならpurgeしない。同nonceも再grantせずunknown結果は保持。未実装・新公開APIなし。 [設計正本](RAG_DO_REPLAY_FENCE_DESIGN.md)。


## D2b-C1：開始許可のDB部品（2026-10-20）

未接続start gateで最新owner/intake/同意/account/floor/期限と4承認flag＋専用gateを単一CAS前後に確認し、一度消費した許可を再発行しない。unknown/timeout/flag停止後の消費はresetしない。既存floorのno_replaceもschema必須。追加のopaque claim metadataは実VM/停止証拠ではなく、取消/account削除でも保持。新protocol親DELETE保留。HTTP/private/configへの接続、物理DO purge、backup安全性の完成は未実施。 [検証と制約](RAG_PDF_START_GATE_REPORT.md)。
