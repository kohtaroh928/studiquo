# vuln-watch

studiquoが使う依存ライブラリ(npm・Swift Package)の脆弱性を、NVD・OSV・JVN iPedia・CISA KEV・EPSSから集めて、優先度順にMarkdownで報告するツール。設計は `docs/VULN_WATCH_DESIGN.md`。

外部パッケージは使わない(Node 20以上)。読み取り専用で、コードや依存は書き換えない。

## 使い方

```bash
cd scripts/vuln-watch
node src/cli.js inventory                 # 資産台帳 inventory.json を作り直す
node src/cli.js scan                      # 収集→照合→採点。out/latest.md(機械判定のみ)と out/triage-input.json を出す
node src/cli.js triage-apply --verdicts f # エージェントの返信を検証して反映し、out/latest.md を上書きする
npm test                                  # 単体テスト
```

主なオプション: `--offline`(キャッシュだけで動かす)、`--no-nvd`、`--no-jvn`、`--out <dir>`、`--swift-resolved <path>`。

終了コード: `0`=完了 / `1`=失敗 / `2`=取得に失敗したデータ源があり結果が不完全 / `3`=LLM判定が反映されなかった / `4`=その両方(取得失敗あり、かつ判定なし)。取得に失敗したデータ源があるときは、判定が付いても区分は下げない。

## 定期実行の1回分(LLM判定つき)

スケジュールタスクの親セッションが行う手順。

1. `node src/cli.js scan` を実行する。終了コード2なら、レポート冒頭の警告を報告に含める。JVNの件数が上限(200件)を超えたときも、ここに警告が出る。
2. `dependency-monitor` エージェントを呼び、`scripts/vuln-watch/out/triage-input.json` を渡して判定させる。エージェントはJSONだけを返す(読み取り専用で、ファイルは書かない)。
3. 返信を `triage-apply` の標準入力に渡す: `node src/cli.js triage-apply < reply.json`(返信をそのままファイルか標準入力に渡し、親が内容を書き換えない)。
4. `out/latest.md` を報告する。終了コード3(判定が反映されなかった)のときは、機械判定のみである旨を添える。

## ファイル

| ファイル | 内容 | git |
|---|---|---|
| `assets.manual.json` | 手書き補足。`sensitive`(認証・課金・個人情報)、`usage`、`exposure`、`nvd`(NVD・JVN検索のキーワード、vendor、product、`jvn.keyword`) | 管理する |
| `inventory.json` | 自動生成の資産台帳。Swift分は `Package.resolved` が見つからないとき前回分を引き継ぐ | 管理する |
| `out/` | レポート、`latest.json`、`triage-input.json`、`triage-result.json` | 管理しない |
| `.cache/` | 取得結果のキャッシュ(6時間) | 管理しない |
| `state.json` | 前回成功時刻と報告済みの指摘ID(「新規/継続」の印に使う)。取得に失敗したデータ源があった回は保存しない | 管理しない |

## 設定

- `NVD_API_KEY`: 環境変数、または `~/.config/studiquo/vuln-watch.env` に `NVD_API_KEY=…`。無くても動くが、NVDの問い合わせが1件6.5秒間隔になる。リポジトリには置かない。
- `VULN_WATCH_SWIFT_RESOLVED`: `Package.resolved` の場所。既定はリポジトリ直下の `studiquo.xcodeproj/.../Package.resolved`(git管理外のため、ワークツリーでは見つからないことがある)。

## 資産にヒントを足すとき

`assets.manual.json` の `nvd` に `keyword`・`products`、できれば `vendors` を書く。`vendors` を書いたときだけ、NVDの一致を「確定」にできる(例: minimistのvendorは `substack`)。JVNの一致は、版が分からないため常に「要確認」になり、エージェントが概要文の版範囲を台帳の版と突き合わせる。
