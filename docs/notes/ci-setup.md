---
title: CIとGitHub設定の手順
date: 2026-10-18
tags: [security, ci, github]
---

# CIとGitHub設定の手順

`.github/workflows/ci.yml`と`.github/dependabot.yml`を足した。GitHubの設定は**自分で**変更する(この変更では何も変えていない)。

## CIが行うこと

- `worker`ジョブ: `mcp-server`で`npm ci --ignore-scripts`、`npm test`。
- `audit`ジョブ: `npm audit --omit=dev`。新しい勧告はPRと無関係に出るので、**必須チェックにしない**(週1回の定期実行でも動く)。
- `secrets`ジョブ: 履歴全体をgitleaksとtrufflehog(`--no-verification`)で検査する。ツールはリリースファイルを取得し、固定したSHA-256で照合してから実行する。
- 動く時: プルリクエスト、mainへのpush、毎週月曜(新しい勧告を拾うため)。
- 守っている決まり: `permissions: contents: read`、secretsを使わない(フォークのPRで安全)、actionはすべて40文字のコミットSHAで固定、デプロイしない。クラウドの鍵はGitHubに置かない。
- 公開リポジトリの定期実行(schedule)は、60日間リポジトリに動きがないとGitHubが自動で止める。止まったらActionsの画面から有効に戻す。
- iOSのビルド・テストは入れていない(macOSランナーの費用と署名の都合)。必要になったら別に判断する。

## GitHubで行う設定(あなたがやる)

Settings > ... で次を行う。名前はGitHubの画面の表記。

1. **公開か非公開か**(Settings > General > Danger Zone): いまは公開。意図しないなら非公開にする。公開のままなら、docsの内部資料と、`wrangler.jsonc`のKV・D1のIDが見えることを許容するか決める。
2. **mainの保護**(Settings > Rules > Rulesets > New branch ruleset、対象は`main`):
   - Restrict deletions、Block force pushes を有効。
   - Require status checks to pass を有効にして、`Worker tests`と`Secret scan (full history)`を必須にする(`Dependency audit`は必須にしない)。**CIが一度動いてから**選べる(チェック名が候補に出る)。
   - 1人で開発するなら Require a pull request before merging は任意(入れるとself-mergeになる)。
3. **Dependabot**(Settings > Code security): Dependabot alerts、Dependabot security updates を有効。`dependabot.yml`のバージョン更新は、これが有効なら動く。
4. **Actions**(Settings > Actions > General):
   - Actions permissions を「Allow ... and select non-... actions」にして、GitHub公式のactionだけを許可する(いまは all)。
   - Workflow permissions を「Read repository contents and packages permissions」にする。
   - 「Require actions to be pinned to a full-length commit SHA」を有効にする(ci.ymlは固定済み)。
   - Fork pull request workflows: 「Require approval for all outside collaborators」にする。
5. **その他**: Automatically delete head branches を有効。Personal access tokens(Settings > Developer settings)に使っていないものが残っていないか確認。

## SHA固定したものの更新

- actionは、Dependabotが新しいSHAのPRを出す(コメントのバージョンも一緒に直る)。
- gitleaks / trufflehogは、`ci.yml`の`env`にあるバージョンとSHA-256を一緒に替える。新しいSHA-256は、リリースの`*_checksums.txt`から取る。
  - 現在: gitleaks 8.30.1、trufflehog 3.99.2。

## Swiftパッケージの更新(手動)

GoogleSignIn、RevenueCat、SwiftMathは`project.yml`で宣言する(XcodeGen)。Dependabotは読めないので、月に1回ほど次を行う。

1. `project.yml`の`packages`で、各パッケージの最新のタグと変更点を確認する(SwiftMathはコミット固定の理由がコメントにある)。
2. 上げる場合は`from:`を替え、`xcodegen generate`してビルドとテストを通す。
3. 脆弱性の勧告(GitHub Advisory)に該当がないかも見る。

## 注意

- PRは`.gitleaks.toml`、`.trufflehog-exclude-paths`、`ci.yml`自体を書き換えて、検査から外れることができる。これらの変更は差分で必ず目で見る。
- gitleaks / trufflehogの版とSHA-256はDependabotが見ない。Swiftパッケージの月次点検と一緒に、ツールの新版も確認する。

## 残り

- 秘密のスキャンで、公開リポジトリの`codex/rag-wip`に残る検出がある(CIが見るのはPRとmainの履歴で、これには入らない)。トリアージは別カード。
- 履歴スキャンの結果と、各サービスの二要素認証の確認も別カード。

Up: [notes 目次](INDEX.md)
