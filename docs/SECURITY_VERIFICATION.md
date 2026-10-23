# セキュリティ検証チェックリスト(MASVS / ASVS)

作成: 2026-10-18。対象: `main` の `b0c97f3` と、同日までに別ブランチで実装済み(未マージ)の変更。

アプリは **OWASP MASVS v2**、Worker API は **OWASP ASVS 4.0.3** の章立てに沿って、要件ごとに「満たすか」「根拠はどこか」「満たさないとき次は何か」を記録する。脅威の洗い出しは[THREAT_MODEL.md](THREAT_MODEL.md)。

## 0. この表の限界

- **これは自己評価であり、監査ではない。** 根拠はコードとテストの読み取りで、実機・本番での動作確認ではない。外部の診断は未実施(カード「外部ペネトレーションテストを手配する」)。
- MASVS v2 の管理項目の名前・番号は、独立レビューで公式の一覧と照合した(一致)。ASVS は**章(V1〜V14)と主題の単位**で書き、個別の要件番号までは書いていない。監査やペンテストの前に、公式の最新の一覧と突き合わせて、要件番号つきの表に直す。
- 状態の記号: ○ 満たす / △ 一部 / × 満たさない / － 対象外(理由つき)。「未マージ」は、ブランチで実装済みだが `main` に入っていない。ブランチは `claude/<名前>`。

## 1. 対象レベルと判断

| 対象 | 水準 | 理由 |
|---|---|---|
| アプリ | MASVS **L1 相当**を基本にする。保護ノートの STORAGE / CRYPTO は **L2 相当**を目標にする(MASVS v2 本体にはレベルが無く、レベルは MAS Testing Profile 側の考え方。ここでは「検証の厳しさ」の目安として使う) | 学生の私的な学習資料を扱う。保護ノートは利用者が「守る」と選んだ資料 |
| Worker API | ASVS **レベル2** | 認証、他人のデータの分離、課金、AI費用がある |
| MASVS-RESILIENCE | **対象外** | 脱獄検知・難読化・改ざん検知は、端末の所有者自身が攻撃者の場合は守れない。学習アプリの資産に対して費用が見合わない |
| 証明書のピン留め(MASVS-NETWORK-2) | **しない** | 証明書はCloudflareが更新する。誤ると全員が接続できなくなる。ATSとhttps固定で足りる脅威モデル |

## 2. アプリ: MASVS v2

### STORAGE

| 管理項目 | 状態 | 根拠 | 満たさない/一部の点と次の一手 |
|---|---|---|---|
| STORAGE-1 機微データを安全に保存する | △ | セッションはKeychain `AfterFirstUnlockThisDeviceOnly`(`AuthenticationStore.swift`)。保護ノートはAES-GCMで暗号化(`NotebookEncryptionService.swift`、`NotebookEncryptionServiceTests`)。書き出し・一時ファイルは`completeFileProtection`(`ExportService.swift`、`StudiquoWorkFiles.swift`、`StudiquoWorkFilesTests`)。自動バックアップは`completeFileProtectionUnlessOpen`(`NotebookBackupService.swift`) | 保護ノートの鍵は`ThisDeviceOnly`ではなく、iCloud Keychainで端末の外へ同期される(意図した設計)。SwiftData本体と共有受信箱の保護クラスが既定のまま(カード「端末上の機微データのData Protectionと復号中データの露出を強化する」)。自動バックアップは保護ノートでも平文JSON(`SECURITY_AND_PRIVACY.md`)。保護ノートの鍵が上書きされうる不具合(ブランチ`claude/key-safety`で修正、**未マージ**) |
| STORAGE-2 機微データの漏えいを防ぐ | △ | URLキャッシュは退会で消去(`AccountFileEraser.swift`)。ログにノート本文を出さない運用 | 一時計測の`print`(`GestureDiagnostics`)はDEBUGビルドだけに限った(呼び出し自体は残っている)。アプリスイッチャー・ペーストボード・ブラウザデータはブランチ`claude/switcher-privacy`・`claude/net-app`で修正、**未マージ**。ロック画面の通知プレビューを隠す設定が無い(カード「チャット通知のプレビューを隠す設定」)。画面収録の検知は無い(カード「画面収録・スクリーンショット時の保護ノート…」) |

### CRYPTO

| 管理項目 | 状態 | 根拠 | 満たさない/一部の点と次の一手 |
|---|---|---|---|
| CRYPTO-1 強い暗号を使う | ○ | CryptoKitのAES-256-GCM、乱数は`SecRandomCopyBytes`(`SignInNonce.swift`)。独自暗号は無い。WorkerはWebCryptoのHMAC・AES-GCM | — |
| CRYPTO-2 鍵を適切に管理する | △ | 鍵はKeychainに保存し、iCloud Keychainで同期。ポリシーに「ゼロ知識暗号ではない」と明記 | 鍵の上書き(未マージの修正あり)。鍵の入れ替え・失効・バックアップの運用手順が無い(カード「保護ノートの鍵の運用」) |

### AUTH

| 管理項目 | 状態 | 根拠 | 満たさない/一部の点と次の一手 |
|---|---|---|---|
| AUTH-1 認証・認可のプロトコルを安全に使う | △ | Apple/Googleは署名・audience・issuer・期限・nonceを検証(`apple-auth.test.js`、`google-auth.test.js`、`REQUIRE_ID_TOKEN_NONCE`)。パスキー(`passkeys.test.js`)。トークンは署名つき(`token-signature.test.js`)・90日・失効可(`revocation.test.js`)。アプリはnonceを生成(`SignInNonceTests`) | 最小長を12文字にした(2026-10-21、ブランチ`claude/sec-ops`、`app.test.ts`「a password under 12 characters…」)。既存の8〜11文字のパスワードはサインインできる(次の変更時から12文字)。パスキー強制の配備と実機確認が未了(カード「AiTMフィッシング対策…」) |
| AUTH-2 端末上の認証 | △ | `DeviceAuthentication`(`.deviceOwnerAuthentication`、`DeviceAuthenticationTests`)で保護ノートを開く前に確認 | 鍵そのものは生体認証に結合されない(同期との両立のため)。手続き上のゲートであることを`NotebookEncryptionKeyStore`の注記とポリシーに明記済み(意図した制限) |
| AUTH-3 機微な操作の追加認証 | △ | 保護の**解除**は端末認証が必要(`ContentView.toggleNotebookProtection`。有効化は認証なし)。退会は確認文字列の入力が必要(`AccountDeletionUI.requiredConfirmation`、`AccountDeletionIOSTests`)。パスキーを持つアカウントの退会はパスキーの再認証が必要(`/api/passkeys/reauth/*`、`PasskeyReauth.isRequired`) | 実装した(ブランチ`claude/sec-ops`): アプリは退会の前に端末認証(Face ID/パスコード。端末にパスコードが無ければ省く)を求める。サーバーは`REQUIRE_RECENT_LOGIN_FOR_DELETION="true"`のとき、パスキー未登録のアカウントに**直近10分以内のサインイン**を求める(`recent_login_required`)。**この設定は、アプリが出てから有効にする**(旧アプリは403を「削除できません」としか表示しない)。有効にするまでは、サーバー側の追加認証は無い |

### NETWORK

| 管理項目 | 状態 | 根拠 | 満たさない/一部の点と次の一手 |
|---|---|---|---|
| NETWORK-1 通信を保護する | ○ | ATSの例外なし(`Info.plist`に`NSAppTransportSecurity`なし)。Releaseは`api.studiquo.app`のhttpsだけ(`WorkerEndpointPolicy`、`WorkerEndpointPolicyTests`) | サーバー側の平文http受付とHSTS無し(ブランチ`claude/net-server`で修正、**未マージ**。Cloudflareの設定はカード「HTTPSの強制とHSTS」) |
| NETWORK-2 相手の身元を確認する(ピン留め) | － | §1の判断 | — |

### PLATFORM

| 管理項目 | 状態 | 根拠 | 満たさない/一部の点と次の一手 |
|---|---|---|---|
| PLATFORM-1 IPCを安全に使う | △ | 招待URLはスキーム・ホスト・パスを検証して確認ダイアログを経る(`FriendStore.add(url:)`、`FriendStoreTests`)。Universal Linkは`/invite`のみ(`invite.test.js`)。共有拡張はApp Group経由で確認画面を経る(`SharedInboxTests`、`SharedImportRunnerTests`) | カスタムスキーム`studiquo://`は他アプリが横取りしうる。不明なURLで画面が移動する(ブランチ`claude/net-*`、**未マージ**。カード「フレンド招待…」) |
| PLATFORM-2 WebViewを安全に使う | △ | 遷移はhttp/httpsに限る(`webBrowserNavigationPolicy`、`WebBrowserNavigationPolicyTests`)。JavaScriptブリッジなし | 永続のデータストアが退会・サインアウトで消えない(ブランチ`claude/net-app`で修正、**未マージ**) |
| PLATFORM-3 UIを安全に使う | △ | 保護ノートはバックグラウンドで再封印(`NoteEditorView`) | アプリスイッチャーの画像(ブランチ`claude/switcher-privacy`、**未マージ**) |

### CODE

| 管理項目 | 状態 | 根拠 | 満たさない/一部の点と次の一手 |
|---|---|---|---|
| CODE-1 最低OSを要求する | ○ | iOS 17.0(`project.yml`) | — |
| CODE-2 更新を強制できる | △ | サーバーの`MIN_APP_BUILD`が426を返す(`low-priority-hardening.test.js`) | アプリが426を表示しない(ブランチ`claude/kill-switch-app`で修正、**未マージ**) |
| CODE-3 既知の脆弱性のある部品を使わない | △ | 依存は少ない(GoogleSignIn、RevenueCat、SwiftMath=コミット固定)。Workerの`npm audit`は0件(手動) | 自動の監視が無い(CI・Dependabotはブランチ`claude/ci-setup`、**未マージ**。カード「CIを新設する…」) |
| CODE-4 信頼できない入力を検証する | △ | docxの1エントリ上限(`DocxZipTests`)。画像・PDF・docxの取り込み上限(ブランチ`claude/import-hardening`、`ImportLimitsTests`、**未マージ**) | `main`には全体の上限が無い。ファジングが無い(カード「ファジング…」) |

### RESILIENCE(対象外)

| 管理項目 | 状態 | 理由 |
|---|---|---|
| RESILIENCE-1 〜 4(プラットフォームの完全性、改ざん対策、静的解析対策、動的解析対策) | － | §1。脱獄端末の検知・難読化は行わない。サーバー側の不正対策(レート制限、App Attest=ブランチ`claude/app-attest`、**未マージ**)で補う |

### PRIVACY

| 管理項目 | 状態 | 根拠 | 満たさない/一部の点と次の一手 |
|---|---|---|---|
| PRIVACY-1 機微データへのアクセスを最小にする | ○ | 許可はカメラ・Face ID・写真とプッシュ通知(`Info.plist`、`UIBackgroundModes: remote-notification`)。Info.plistは`xcodegen generate`で作る生成物で、正本の`project.yml`と文言が食い違う箇所がある(再生成で解消)。AIには選んだ資料だけを送る(`AIPrivacyConsentTests`、`AIDataDisclosureTests`) | — |
| PRIVACY-2 利用者の識別を防ぐ | △ | サーバー側の識別子はハッシュ。サインインの文脈は国とネットワークの識別子だけ | ハッシュは塩なしSHA-256で、メール/IPが既知なら照合できる(`SECURITY_AND_PRIVACY.md`の既知の課題)。「仮名化であり匿名化ではない」とポリシーに明記(ブランチ`claude/policy-facts`、**未マージ**) |
| PRIVACY-3 収集と利用が透明 | △ | Privacy Manifest、ポリシー、AI同意文 | Manifest・ポリシー・申告のずれ(ブランチ`claude/policy-facts`の照合表、**未マージ**)。越境移転・外部送信・特商法は法務確認待ち(カード「法務確認」) |
| PRIVACY-4 利用者が制御できる | ○ | 退会(`AccountDeletionIOSTests`、`account-deletion.test.js`)。診断は既定オフ(`ErrorReportServiceTests`)。AIは同意制(`AIPrivacyConsentTests`)。iCloud同期は切り替え式(`ICloudSyncTests`) | iCloud上のデータは退会で消えない(ポリシーに明記) |

## 3. Worker API: ASVS 4.0.3(章ごと)

| 章 | 状態 | 根拠 | 満たさない/一部の点と次の一手 |
|---|---|---|---|
| V1 アーキテクチャ・設計 | △ | `ARCHITECTURE.md`、`THREAT_MODEL.md`、信頼境界の整理、段階配備のフラグ | `app.test.ts`の`ROUTES`表に全`/api`ルートと認証の種別を列挙し、表に無いルートがあるとテストが落ちる。トークン無し・未発行のトークン・Access無しの拒否を全ルートで確認する(ブランチ`claude/sec-ops`)。所有者/メンバー/非メンバーの網羅は、ルーム系の個別テスト(`chat.test.ts`、`document-collab.test.ts`)のまま |
| V2 認証 | △ | Argon2id+PBKDF2の旧形式対応(`local-auth.test.js`)、漏えいPW照合(`pwned-passwords.test.js`)、失敗の段階的待機(`login-throttle.test.js`)、確認コードは1回・15分・5回(`email-verification.test.js`)、パスキー(`passkeys.test.js`)、新環境のサインイン通知(`login-monitor.test.js`) | 最小長は12文字(新規登録・再設定)。サインインは従来のパスワードも通る。多要素の強制(パスキー)は配備待ち |
| V3 セッション管理 | △ | 絶対期限(90日、更新しても開始から既定365日)、署名つきトークン(`token-signature.test.js`)、実在セッション確認(`session.test.js`)、90日の有効期限と更新(`token.test.js`、`low-priority-hardening.test.js`の「SESSION_MAX_DAYS」)、ログアウトで失効(`app.test.js`「a previously issued token is rejected…after logout revokes it」)、パスワード変更で古いセッションを失効(`session-revocation.test.js`) | 「すべての端末からサインアウト」を利用者が行う機能が無い(カード「すべての端末からサインアウト」) |
| V4 アクセス制御 | △ | ルーム/文書のメンバー確認(`chat.test.js`「someone outside the room cannot…」、`document-collab.test.js`)、アカウント間の分離(`entitlements.test.js`)、管理APIはAccessで毎回検証(`access.ts`、`admin.test.js`)、他サイトからの書き込み拒否(`isCrossSiteWrite`) | 認証の種別の網羅表は上記。メンバー確認の網羅は個別テスト |
| V5 入力の検証・エンコード | ○ | 本文の上限(`app.test.js`「…oversized body is rejected with 413」)、D1は全て`bind`(文字列連結は定数の表名のみ、`privacy-retention.ts`)、HTMLは`htmlEscape`+CSP(`api-hardening.test.js`、`invite.test.js`)、プロンプト区切りの無害化(`ai.ts`) | ファジングが無い(カード) |
| V6 保存時の暗号 | △ | スナップショットはAES-256-GCMで鍵名をAADに束縛(`snapshot-crypto.test.js`)、パスワードはArgon2id、トークンはハッシュで保存 | 鍵が未設定だと平文。チャット本文などのサーバー側暗号化は保留(カード「サーバー側の保存データの暗号化方針」)。配備はカード「スナップショット暗号化…」 |
| V7 エラー処理・ログ | △ | 本文・画像・鍵をログに出さない運用、`invocation_logs`無効、エラー応答は汎用 | OpenAIのエラー本文のログ出力はやめた(`type`と`code`だけ。`ai.test.ts`)。アラートは[MONITORING.md](MONITORING.md)の一覧に拡張した(500・AI上流・スナップショット・保持ジョブ・削除ジョブ・MCPトークン再利用)。Cloudflare側の通知と外部の死活監視は未設定 |
| V8 データ保護 | △ | 保持期間と削除(`privacy-retention.test.js`、`account-deletion.test.js`)、`store:false`でAIへ送る(`ai.test.js`) | バックアップと復元の訓練が無い(カード「バックアップと復元」) |
| V9 通信 | △ | TLS、HSTS・平文http拒否はブランチ`claude/net-server`、**未マージ** | `main`はHSTSが無く、平文httpに応答する |
| V10 悪意あるコード | △ | 秘密スキャンを手動で実施 | CI・静的解析が無い(ブランチ`claude/ci-setup`、**未マージ**。カード「静的解析を入れる…」) |
| V11 業務ロジック | △ | AI窓ごとの上限+全体上限(`ai-credits.test.js`)、課金の整合(`entitlements.test.js`)、削除の世代管理(`session-revocation.test.js`) | サインアップの自動化への耐性はApp Attest待ち(**未マージ**) |
| V12 ファイル・リソース | △ | 添付6MB・10回/分(`chat.test.js`)、`nosniff`+sandbox CSP | 添付の種類は形式を検証し(`chat-room.ts`の`CONTENT_TYPE_PATTERN`)、配信は`nosniff`・sandbox・`attachment`で返す(`binaryHeaders`)。アバターは`image/jpeg`・`image/png`の許可リスト。残りの確認はカード「ログに残る秘密値とHTTP周りの細かい指摘」 |
| V13 API・Webサービス | △ | JSON、レート制限(`app.test.js`の各ルート、`api-hardening.test.js`)、OAuth PKCE(`mcp-oauth.test.js`) | 動的クライアント登録は誰でもできる(カード「OAuth動的登録…」) |
| V14 構成 | △ | 秘密はWrangler secrets、台帳(ブランチ`claude/ci-setup`の`RUNBOOK.md`付録A、**未マージ**)、環境の分離(ステージング) | 公開リポジトリ、ブランチ保護なし、`preview_id`が本番と共通 |

## 4. 検証の頻度

- 変更のたびに: 認証・認可・入力検証・データ保護に触れる変更は、独立レビューを受け、該当する行の状態と根拠を更新する。
- リリースの前に: §2・§3の「△」「×」を見直し、残すものは理由と期限をカードに書く。
- 半年ごとに: §1の判断(ピン留め・脱獄検知など)が今も成り立つか見直す。

## 5. 満たさない/一部の点から切り出したカード

Notionの「Studiquo タスク」に作成済み(名前で検索する)。既存のカードで足りるものは、新しく作っていない。

新規に作ったカード:

| 項目 | 関係する管理項目/章 |
|---|---|
| パスワードの最小長を12文字以上にする方針 | AUTH-1、V2 |
| 一時計測のprintを製品から外す | STORAGE-2、CODE |
| チャット通知のプレビューを隠す設定 | STORAGE-2、PRIVACY-4 |
| 保護ノートの鍵の運用(入れ替え・失効・バックアップ・iCloud Keychain無効時) | CRYPTO-2 |
| すべての端末からサインアウトする機能 | V3 |
| 認可の網羅テスト(ルート×所有者/メンバー/非メンバーの表) | V1、V4 |
| 外部エラー応答の本文をログに出す箇所 | V7 |
| D1・KV・DOのバックアップと復元の訓練(RPO/RTO) | V8、V14 |
| サーバー側の保存データの暗号化方針 | V6、V8 |
| パスキー未登録アカウントの退会に再認証を求める | AUTH-3 |
| 検証済みメールの所有権が移ったときのアカウントの引き継ぎ | V2、V4、THREAT_MODEL A2 |

既存のカードで扱うもの(再掲): App Attest、CIの新設、静的解析、ファジング、ペネトレーションテスト、security.txt、異常検知のアラート、HTTPSとHSTS、招待リンク、OAuth動的登録、スナップショット暗号化の配備、AiTM対策の配備、端末のData Protection、CloudKitの実機確認、DNS設定、法務確認、GitHubの公開範囲。
