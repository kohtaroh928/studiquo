@AGENTS.md

## Antigravity向けの補足

共通ルール・開発手順モード・Notionでのタスク管理は`AGENTS.md`が正本である。ここには重複して書かない。

- 役割別エージェントの定義は`.agents/skills/`にある。許可ツールの範囲はAntigravityでは強制されないため、各定義の「許可ツールの目安」を自分で守る。
- 他のエージェント(Codex、Claude Code)が同じ作業ツリーで作業している場合がある。着手前に`git status`で未コミット変更を確認し、他者の変更を編集・revert・stashしない。
- 並行作業は`git worktree`でブランチを分ける。ブランチ名の接頭辞は`antigravity/`とする。フックがエージェントを識別できるよう、Git操作時に`AGENT_NAME=antigravity`を設定する。
- `.git/index.lock`が残っていても削除せず、待つ。
- main直接コミット、push、merge、deployはしない。
