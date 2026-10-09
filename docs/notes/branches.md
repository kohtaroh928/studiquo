---
title: ブランチと作業中の状態
date: 2026-10-08
tags: [status, git, branches]
---

# ブランチと作業中の状態

2026-10-08 夜(日本時間)のスナップショット。`git`の状態から作った。古くなるので、日付を見て使う。

## いまの作業ツリー

- 現在のブランチは`codex/email-code-rate-limit`(`main`より27コミット先)。
- 未コミットの変更が35ファイルある。`docs/ARCHITECTURE.md`、`docs/SECURITY_AND_PRIVACY.md`、`docs/releases/2026-10-08-worker-update.md`のほか、`mcp-server/`の削除・AI・セッション関連、`studiquo/`のモデル・AI・認証・エディタ関連、各種テストを含む。
- 直近のコミットは「パスキーの登録を、サインイン中のアカウントが所有するメールに限る」(`75673e4`)。

## `main`へ未マージのブランチ

| ブランチ | `main`との差 | 最新のコミット |
| --- | --- | --- |
| `codex/fix-deletion-reregistration` | 31先 | パスワードの再設定で、以前のセッションと連携アプリを失効させ、別名の退会中も守る |
| `feature/files-browser-pane` | 28先 | ノートの分割画面で、ファイルアプリの資料を元の場所のまま開けるようにする |
| `codex/email-code-rate-limit` | 27先 | パスキーの登録を、サインイン中のアカウントが所有するメールに限る |
| `codex/split-picker-layouts` | 20先 | 分割画面の資料選択に、リスト・アイコン・カラムの並べ方切り替えを追加する |
| `feature/share-import` | 3先 | 共有取り込みの回帰テストを追加し、取り込みの流れをテストできる形に切り出す |
| `feature/ai-pane-tab-drop` | 2先 | レビュー指摘の反映: Web画面の受け皿をタブのドラッグ中だけ有効にする |
| `codex/friend-screen` | 1先 | フレンド画面: 申請・招待を一つにまとめ、スワイプ削除・ブロックと自己紹介の共有を追加する |
| `fix/cloudkit-mainactor` | 1先 | `@MainActor`を`CloudKitSyncStatus`に戻し、コメントの対応を直す |
| `fix/ui-test-drag-timing-and-fixtures` | 1先 | ライブラリのUIテストの失敗4件を、テストの前提のずれとして修正する |

## `main`へマージ済みのブランチ

`feature/home-multi-select`、`feature/icloud-sync-optin`、`feature/ai-math-rendering`、`feature/announcements`、`feature/error-reports`、`feature/more-tab`、`feature/notification-banners`、`fix/scribble-erase`、`codex/ai-chat-message-actions`、`codex/security-scanning`、`test/more-tab-ui-tests`

整理の候補。ただし、削除は自分で確認してから行う。

## worktree

2026-10-08 23時ごろ、ホーム直下の`studiquo-*`のうち5つを`~/studiquo/.worktrees/`へ移した。`.git/info/exclude`に`/.worktrees/`を入れてあるので、Gitの差分には出ない。

| 場所 | ブランチ |
| --- | --- |
| `.worktrees/ai-pane-drop` | `feature/ai-pane-tab-drop` |
| `.worktrees/fix-ui-tests` | `fix/ui-test-drag-timing-and-fixtures` |
| `.worktrees/icloud-sync` | `feature/icloud-sync-optin` |
| `.worktrees/share-import` | `feature/share-import` |
| `.worktrees/split-picker` | `codex/split-picker-layouts` |

ホーム直下に残したもの(未コミットの変更があり、移さなかった):

- `~/studiquo-files-pane`(`feature/files-browser-pane`)
- `~/studiquo-fix-deletion`(`codex/fix-deletion-reregistration`)

この2つは、コミットか退避をしてから、`git worktree move`で`.worktrees/`へ移せる。

その他:

- `~/.codex/worktrees/`の3つ(`ai-chat-message-actions`、`friend-screen`、`security-scanning`)はCodexが管理しているので、触っていない。
- `/private/tmp/claude-501/`配下の4つは一時的なもの。うち`wt-tests`は、Mac側のGitでも`prunable`と出る(実体がない)。残りの3つはdetached HEADである。
- Claudeのクラウド側の作業環境から`git worktree list`を実行すると、Macのパスが見えず、ほぼ全部が`prunable`と表示される。これは表示上のもので、不要という意味ではない。**`git worktree prune`は、必ずMac上の端末で実行する。**

## リリースの下書き

- [Worker更新のリリース記録 2026-10-08](../releases/2026-10-08-worker-update.md)は下書きで、未コミット。
- 本番反映の順序と条件は[PRIVACY_RELEASE_CHECKLIST](../PRIVACY_RELEASE_CHECKLIST.md)を参照。

## Gitに追跡されていないdocs

2026-10-08時点で、次のdocsはコミットされていない(`git status`で`??`)。`git log --all`でも、どのブランチにも履歴がない。Gitには写しがないので、このMacのファイルが唯一の写しになる(iCloudやTime Machineなど、Git以外のバックアップは確認していない)。

- 本文: `DATA_AND_MIGRATIONS.md`、`PRIVACY_RELEASE_CHECKLIST.md`、`RELEASE_CHECKLIST.md`、`RUNBOOK.md`、`HYBRID_RAG.md`、`RAG_*.md`(7ファイル)
- 評価の生データ: `RAG_*.json`(8ファイル)

コミットするかどうか、評価の生データをリポジトリに入れるかどうかは、自分で決める。`docs/INDEX.md`と`docs/notes/`もこの時点では未追跡である。

Related: [未決事項](open-decisions.md)、[DEVELOPMENT_WORKFLOW](../DEVELOPMENT_WORKFLOW.md)
