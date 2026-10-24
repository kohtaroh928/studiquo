# CI(継続的検査)

最終更新: 2026-10-19

GitHub ActionsとXcode Cloudを併用する。同じ検査を二重に走らせないよう、役割を分ける。

| 役割 | ツール | 設定の場所 | 実行のきっかけ |
| --- | --- | --- | --- |
| Workerのテスト、`npm audit`、秘密スキャン(全履歴) | GitHub Actions(Linux) | `.github/workflows/ci.yml`(`claude/ci-setup`ブランチ。手順は`docs/notes/ci-setup.md`) | 全PR、mainへのpush、毎週月曜 |
| iOSのビルドとユニットテスト | GitHub Actions(macOS) | `.github/workflows/ios.yml` | mainへのpush、手動、アプリ関連ファイルを変えたPR |
| アーカイブ・署名・TestFlight配信 | Xcode Cloud | Xcode / App Store Connect(下記) | 人間が決める(例: リリース用タグ) |

## iOSのワークフロー

- `.xcodeproj`はリポジトリに入れず`project.yml`から生成するので、実行のたびに`xcodegen generate`する。
- テストは`studiquoTests`だけ(UIテストは含めない)。シミュレータは利用できるiPadを自動で選ぶ。署名は無効(`CODE_SIGNING_ALLOWED=NO`)。
- macOSランナーは分数の消費が大きい。実行条件を広げるときはコストを確認する。
- 決まり(`ci.yml`と同じ): secretsを使わない、`permissions: contents: read`、actionはコミットSHAで固定(Dependabotが更新を提案)。

## Xcode Cloud

- `ci_scripts/ci_post_clone.sh`がクローン直後に`xcodegen generate`を実行する(Xcode Cloudの決まった場所と名前)。
- ワークフロー自体はXcodeで作る(リポジトリのファイルでは作れない)。手順:
  1. Xcodeの Product > Xcode Cloud > Create Workflow を開く。
  2. リポジトリへのアクセスをGitHubで許可する。
  3. アクションは Archive(iOS)。テストはActionsが担当するのでここでは省く。
  4. 開始条件は、タグなど人間がリリースを決めた時点に絞る。
  5. 配信先に TestFlight を設定する。
- 署名はXcode Cloudの自動署名に任せる。証明書や鍵をリポジトリ・Actionsには置かない。

## ブランチ保護

mainの必須チェックは`docs/notes/ci-setup.md`の手順どおり(`Worker tests`と`Secret scan (full history)`)。iOSは実行を絞っているので必須にしない(必須にすると、アプリ以外のPRが待ち続ける)。
