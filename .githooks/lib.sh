#!/bin/sh
# Claude / Codex / Antigravity の作業が同じブランチ・同じフォルダで被らないようにする共通判定。
# 一時的に回避するときは STUDIQUO_ALLOW_SHARED_CHECKOUT=1 を付ける(人が手動で作業する場合など)。

is_main_checkout() {
  [ "$(git rev-parse --absolute-git-dir)" = "$(git rev-parse --path-format=absolute --git-common-dir)" ]
}

# AGENT_NAME(claude / codex / antigravity)があればそれを、なければ作業フォルダのパスから推定する。
agent_name() {
  if [ -n "$AGENT_NAME" ]; then
    echo "$AGENT_NAME"
    return
  fi
  case "$(git rev-parse --show-toplevel)" in
    */.codex/worktrees/*) echo codex ;;
    *) echo "" ;;
  esac
}

current_branch() {
  git symbolic-ref --quiet --short HEAD 2>/dev/null
}
