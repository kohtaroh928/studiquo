#!/usr/bin/env bash
# 秘密情報の混入を、全履歴に対して検査する。マージ前に実行する。
#   gitleaks   : コミット履歴(全ブランチ)
#   trufflehog : コミット履歴(検出した秘密を外部に問い合わせない --no-verification)
# どちらかが1件でも検出したら失敗(終了コード1)する。
# trufflehog の場所は TRUFFLEHOG で上書きできる(例: TRUFFLEHOG=~/bin/trufflehog)。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

TRUFFLEHOG="${TRUFFLEHOG:-trufflehog}"
for tool in gitleaks "$TRUFFLEHOG"; do
  command -v "$tool" >/dev/null || { echo "$tool が見つかりません。" >&2; exit 2; }
done

echo "== gitleaks"
gitleaks git --redact --no-banner --config .gitleaks.toml --log-opts="--all"

echo "== trufflehog"
# Eraser: 変数名 eraser に反応する誤検知が多いため除外(Eraser のAPIキーは使っていない)。
"$TRUFFLEHOG" git "file://$PWD" --no-verification --no-update --fail \
  --exclude-detectors=Eraser --exclude-paths=.trufflehog-exclude-paths

echo "秘密情報の検出はありません。"
