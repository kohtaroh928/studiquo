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
| 共同編集状態 | `DOCUMENT_ROOM` | 許可された参加者(アカウントごとのキー) | 持ち主の削除で部屋ごと消去。招待されただけの人の削除では、その人の席と、未決・却下の提案を消去し、承認済みの提案は書いた人のキーを外して残す(ADR-0004) |
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
- 副ペインの「ファイルアプリと2分割」は、選んだファイルをコピーせず元の場所のまま読み取り専用で開く。表示中だけsecurity-scopedアクセスを保持し、ペインを閉じる・別の内容へ切り替える・分割を畳む時に解放する。
- 開いたファイルの履歴（表示名とブックマーク）は`Library/Application Support/studiquo/ExternalFileBookmarks.json`に保存する。端末固有のためバックアップ対象から外し、ログ・エラーレポート・識別子へパスやファイル名を出さない。アカウント削除ではこの履歴を消すが、元のファイルは消さない。

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

初期提供先はGoogleのみとする。旧モデル定義は内部に残るが、アプリの選択肢と公開API境界で制限し、direct Anthropic経路は拒否する。開いているノートは自動添付しない。

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
