# 初回セキュリティ検査結果

実施日: 2026-10-06 (JST)  
作業ブランチ: `codex/security-scanning`  
状態: 検査基盤を実装。Swiftの解析範囲とZAP本体実行は未完了。

## 実行した検査

| 検査 | 結果 |
|---|---|
| 既存サーバーテスト | 508件成功 |
| SASTレポート・エラー判定テスト | 6件成功 |
| Semgrep実エンジンのルールfixture | 検出すべき14例、安全な11例を確認 |
| DAST安全境界・結果検証・実runtimeテスト | 3件成功 |
| 実Workers HTTP契約 | 20項目成功、架空ユーザー2人 |
| Semgrep 1.179.0 | 316ファイルを対象に11指摘。4ファイルPartialParsingで不完全、exit 2 |
| Gitleaks 8.24.3 | Git全履歴と現在の作業ツリーで2指摘。下記の公開文字集合の誤検出 |
| npm audit | 7パッケージに既知脆弱性。配布依存3、開発専用4 |
| ZAP 2.16.1 | Linux/Dockerがないため本体は未実行 |
| GitHub Actions | ローカルにworkflowを追加。push・リモート実行は未実施 |

秘密値、ノート本文、Git author/email、スキャナーの証拠本文をレポートへ保存していない。詳細の機械生成要約は `security-reports/sast/summary.json`・`summary.md` と `security-reports/dast.json`・`dast.md` に保存する。これらはGit管理対象外。

## 依存関係の指摘

Critical/High等はnpm/GitHub advisoryの評価であり、Studiquoで攻撃が成立することを確認した評価ではない。同じ脆弱性が親パッケージへ波及して件数に含まれるため、7パッケージ＝7種類の脆弱性という意味ではない。

| パッケージ | npmの重要度 | 依存範囲 | 現時点の判定(2026-10-23 再確認) |
|---|---|---|---|
| proxy-addr | Critical(2.0.7 のとき) | MCP SDK→Express | ロックファイルは 2.0.8(修正版)に更新済み。Workers出力には含まれない |
| fast-uri | High(3.1.6 のとき) | MCP SDK→Ajv | ロックファイルは 3.1.8(修正版)に更新済み。Workers出力には含まれるが、攻撃者がURIを渡す経路は見つかっていない |
| ip-address | Moderate(10.5.0 のとき) | MCP SDK→express-rate-limit | ロックファイルは 10.7.4(修正版)に更新済み。Workers出力には含まれない |
| undici・sharp(miniflare経由) | High | 開発専用 | `mcp-server/package.json` の `overrides` で undici 7.29.1・sharp 0.35.5 に固定して解消。本番へ配布する依存ではない |

`npm audit`(`mcp-server`)は、本番依存・開発依存とも指摘0件(2026-10-23)。上の表の古い版番号は、最初の検査時点の値として残している。

根拠:

- [proxy-addrのIP偽装](https://github.com/advisories/GHSA-jqcg-44mw-7w3h): 修正版2.0.8。IPv4-mapped IPv6の信頼プロキシ設定を扱う条件がある。
- [fast-uriのauthority injection](https://github.com/advisories/GHSA-qw65-cvwx-89v3): 修正版3.1.7。別のURI関連advisoryもあり、まとめて安全な修正版を選定する。
- [ip-addressの分類不備](https://github.com/advisories/GHSA-rpw4-54j3-4h4q): 複数advisoryがある。最新の安全な修正版と依存側の互換性を確認する。

脆弱性の修正はこの検査導入と分けて行った。major更新とdeployは実施していない。bundle判定は検査用esbuild設定の出力に対するもので、実際の公開済みWorkerを取得・検証した結果ではない。

## コード・秘密情報の指摘の分類

- SQL組み立て: 9指摘（うち2件は既存テスト）。読んだ範囲では固定文字列、制限されたテーブル/列名、`?` placeholderと `.bind()` を使う処理であり、SQL injectionを再現した指摘ではない。
- UserDefaultsへのtoken保存: 2指摘（うち1件は既存テスト）。ログインtokenではなく公開共有する友達招待tokenが対象。認証資格情報保存の脆弱性とは区別する。
- Gitleaksのgeneric-api-key: 2指摘は同じ `LINK_TOKEN_ALPHABET` の現行/履歴。token生成に用いる公開文字集合であり、秘密情報ではない。履歴の定義も同じ公開集合であることを確認した。

以上は自動検出の誤検出・要確認項目として分類した。ルールを全体無効化したり、ファイル全体を秘密検査から除外したりしていない。

## 未完了の検証

Semgrep最新版でも次のSwiftファイルを完全に解析できない。解析エラーを隠さずCI失敗とし、他の検査と部分結果は保持する。

- `studiquo/Services/AppNotificationService.swift`
- `studiquo/Ink/InkCanvasView.swift`
- `studiquo/Services/StudyTimeTracker.swift`
- `studiquo/Views/ProfileAndFriendsView.swift`

これらのファイルに問題がないとは判定できない。商用解析または利用資格を確認したCodeQLで補完する検討が必要。Swift SDKの依存脆弱性検査、iPad実機の動的検査も未カバー。

ZAP本体はLinuxの手動workflowで実行し、6つの許可GETパスへの成功到達と結果JSON生成を確認する必要がある。この確認前にDAST全体の検証完了とは扱わない。ローカルのcontracts-onlyでscanner statusはnot-runと記録する。

検査runtimeは安定版Miniflare4・compatibility date2026-07-30。本番の2026-08-27との差と、Cloudflare edge上のTLS/Access/制限・外部連携の未再現が残る。

## 独立レビューと次の工程

独立した読み取りレビューで、ZAP JSON検証、リクエスト上限、キャンセル、外部通信遮断テスト、レポート出力先の指摘を受けて修正した。修正後に対象テストを再実行した。

運用開始前に、Linux上のZAP実行とSwift解析の補完を完了する。次に依存脆弱性の到達性を評価して修正版へ更新し、初回指摘の分類を踏まえてCIの停止条件を決める。
