# Studiquo セキュリティ自動検査

## 目的と受け入れ条件

コードから危険な実装を検出するSAST、実行中のWorkersへのHTTP検査であるDAST、秘密情報検出、依存関係の既知脆弱性検出を導入する。リスクはHighとして扱う。既存のアプリ/API公開仕様、本番設定、認証・認可処理、データmigrationは変更しない。

- Swiftアプリ・共有拡張とJavaScriptサーバーを解析し、危険/安全なfixtureでルールを検証する。
- 本物のWorkers runtime・認証処理にHTTPリクエストを送り、正常系到達と異常系拒否を確認する。
- 架空ユーザー2人のデータ分離、無効/期限切れ/失効token、管理API拒否を確認する。
- 本番接続、外部通知・AI・課金、秘密値入り成果物を防ぐ。
- ツール不在、解析エラー、対象0件、認証失敗、タイムアウトを「脆弱性なし」と区別する。
- 初回の既存指摘を全件整理する。誤検出には根拠が必要で、一括無視するbaselineは作らない。

## ローカルで実行

作業場所の `mcp-server` で `npm ci` を実行する。必要な外部ツールの固定バージョンと導入方法は `.github/workflows/security-sast.yml` を参照する。Semgrepのアカウント登録やSaaSログインは不要。SAST全体にはmacOSのXcode toolchainが必要で、SwiftParser/SwiftSyntaxを用いてSwiftのファイル全体を検査する。CIはmacos-15-intelで実行する。

```sh
cd mcp-server
npm run security:sast:test
npm run security:sast:rules
npm run security:sast
npm run security:dast:test
npm run security:dast:contracts
npm run security:dast
```

SASTはSemgrep CE、Gitleaks、npm auditを実行し、`security-reports/sast/` に要約を作る。Semgrepのルールテストは `npm run security:sast:rules` を実行する。実際の解析エンジンで検出すべき例と検出してはいけない例を比較する。秘密情報は全Git履歴と現在の検査対象ファイルを調べる。削除済みの秘密が履歴に残る場合も修正済みとは扱わず、失効・ローテーションを別途検討する。

DASTは `security-reports/dast.json` と `security-reports/dast.md` に結果を作る。`--contracts-only` はDocker不要のHTTP境界テストで、ZAP検査の代替とは扱わない。完全なZAP実行にはLinuxとDockerが必要。Docker DesktopのmacOSホスト共有Unix socketは検証対象外。

## 隔離と脅威・障害対策

DASTはWranglerの通常設定や `.dev.vars` を読まず、Miniflareで一時的なローカルKV・D1・Durable Objectsを用意する。実処理は `mcp-server/src/worker.ts` からbundleする。検査用Miniflareは安定版4.20260730.0に固定し、検査のcompatibility dateは2026-07-30。本番の2026-08-27との差があるため、本番と完全に同じruntimeではない。架空セッションは一時KVへ登録し、実際のsession検証を通す。アプリの認証bypassは追加しない。

Workerからの外部fetchはoutbound serviceで拒否する。ZAPは `--network none` のコンテナで実行し、Unix socketを経由した許可済みmethod/pathだけをサーバーへ渡す。秘密値や本文を含むZAP生データは一時領域に限定し、公開成果物へコピーしない。終了・失敗時はプロセスと一時領域を片付ける。指定外のmethod/pathは拒否する。外部接続、リダイレクト、基盤異常、安全上限の超過、到達不足は検査の失敗として報告する。

本番URLを指定する機能は提供しない。API削除、メール送信、AI、課金Webhook、外部OAuthなどは初期ZAP対象に含めない。cronは起動しない。レート制限やTLS、Cloudflare Accessのedge処理の実環境検証には、別途隔離したstagingが必要。

## CIと結果の扱い

SASTはPR・mainへのpush・週次・手動で実行する。DASTは最初は手動で実行する。workflowをリモートへpushしていない段階ではGitHub上の自動実行は開始しない。読み取り権限を基本にし、外部PRへsecretを渡さない。生の秘密値・token・request/response本文をartifactへ入れない。要約の保持期間は14日。

初期モードでは検出結果をレポートし、検査基盤の失敗はCIを失敗させる。レポート専用モードで緑になっても「問題なし」の意味ではない。ルールの重要度はSemgrepのERROR/WARNING/INFOで、CVEのCritical/High等とは別に扱う。確認済み重大問題は修正候補として管理する。SASTの `--enforce ERROR` で重大指摘を停止条件にできる。新規指摘だけを停止する差分判定とGitHub branch protectionの必須check指定は、初回分類後の別工程とする。

npm auditは実行環境に解決された `package-lock.json` の依存を調べる。dev依存の脆弱性とサーバー配布依存を区別する。パッケージにCVEがあることだけでStudiquoから攻撃可能とは断定せず、使用経路と前提条件を確認する。自動fixやmajor更新は行わない。

## 限界と追加候補

SwiftはtoolchainのSwiftParser/SwiftSyntaxで全ソースを構文解析し、既存の4ルール（資格情報保存、信頼処理、資格情報ログ、弱いhash）をAST visitorで検査する。解析エラー、unexpected構文、UTF-8復元不一致、バイト数不一致、ファイル不足、内容のhash不一致は失敗とする。SemgrepがPartialParsingを報告したファイルは、同じ内容を完全にAST解析できた証拠がある場合だけ補完済みと扱う。Swiftルールを増やすときはnative側の検査とfixtureも同時に更新し、全ルールの補完範囲を維持する。対応する同じ場所の重複だけを除去し、未対応の新しいSemgrep指摘は保持する。型解決や関数間データフローを検査する仕組みではない。Semgrep CEのJavaScript解析にも複数関数・複数ファイルにまたがる検出の限界がある。CodeQLはGitHub公開範囲と契約資格を確認してから追加する。Swift向けにはmacOSで署名なしシミュレータbuildが必要で、アプリと共有拡張の両方を含める。現段階ではCodeQL導入済みと主張しない。

Swift依存はXcodeGenの `project.yml` が正本で、リポジトリには解決済み `Package.resolved` がない。今回のnpm auditはSwift SDKを検査しない。SDK版の記録とCVE確認は未カバーとして明示する。iPad実機の保存データ、Keychain、通信、CloudKit、WebSocket、MCP streaming、実OAuthフローも自動DASTの対象外。

## 停止・ロールバックとレビュー

workflowを無効化し、専用の検査ファイルとpackageの検査用dev依存を取り消すことで停止できる。本番データmigrationやアプリの再配布は不要。公開前にCode ReviewerとSecurity Reviewerが、本番接続禁止、外部通信拒否、秘密値の非保存、CIの誤成功防止を独立レビューする。実行できなかった検査と指摘は引き渡し時に明示する。
