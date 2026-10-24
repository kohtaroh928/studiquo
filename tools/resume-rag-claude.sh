#!/bin/sh
# Explicit interactive handoff only. No API keys, permission bypass or Git mutation.
set -eu
rag_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$rag_root"
if [ "$(git branch --show-current)" != "codex/rag-wip" ]; then
    echo 'codex/rag-wip の作業フォルダから起動してください。ブランチは変更していません。' >&2
    exit 1
fi
if ! command -v claude >/dev/null 2>&1; then
    echo 'Claude Codeが見つかりません。通常の導入・認証手順を確認してください。' >&2
    exit 1
fi
for rag_file in AGENTS.md CLAUDE.md docs/RAG_CLAUDE_HANDOFF.md docs/RAG_RESUME_PROMPT.md; do
    test -r "$rag_file" || { echo "引き継ぎ資料が見つかりません: $rag_file" >&2; exit 1; }
done
echo '他担当の編集・テストが停止した状態で、同じ未コミット成果を引き継ぎます。'
exec claude "$(cat docs/RAG_RESUME_PROMPT.md)"
