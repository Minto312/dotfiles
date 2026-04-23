#!/usr/bin/env bash
# ccusage を叩いて today / 過去 30 日のコストをキャッシュに書く。
# statusline.sh からバックグラウンド (fire-and-forget) で呼ばれる前提。
# 多重起動防止に flock を使用。

set -euo pipefail

CACHE_DIR="$HOME/.claude/cache"
CACHE_FILE="$CACHE_DIR/cost-summary.json"
LOCK_FILE="$CACHE_DIR/cost-summary.lock"

mkdir -p "$CACHE_DIR"

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0  # 既に別プロセスが更新中なら何もしない

data=$(bunx ccusage daily --json 2>/dev/null) || exit 1

today=$(date +%Y-%m-%d)
today_cost=$(jq -r --arg today "$today" '
  ((.daily[]? | select(.date == $today) | .totalCost) // 0) | tostring
' <<<"$data")

last30_cost=$(jq -r '
  ((.daily // []) | sort_by(.date) | reverse | .[0:30] | map(.totalCost) | add // 0) | tostring
' <<<"$data")

tmp=$(mktemp "$CACHE_FILE.XXXX")
jq -n \
  --argjson today "$today_cost" \
  --argjson last30 "$last30_cost" \
  --argjson ts "$(date +%s)" \
  '{today: $today, last_30d: $last30, updated_at: $ts}' >"$tmp"
mv "$tmp" "$CACHE_FILE"
