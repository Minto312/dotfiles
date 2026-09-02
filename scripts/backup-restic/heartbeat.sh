#!/usr/bin/env bash
# バックアップの週次 heartbeat を Discord に流す。
#
# 🔴 これは「アラート」ではなく「沈黙を異常のサイン」にするための仕組み。
#    Grafana は develop の上で動いているので、develop や obs スタックが死ぬと
#    アラート自体が死ぬ (自己参照)。毎週 1 通届くことを前提にしておけば、
#    届かなかったこと自体が異常を意味する
#    (machine/storage/backup-develop.md §4.5)。
#
# ⚠ 判定はしない。数えて出すだけ。閾値を超えたら鳴らすのは Grafana Alerting の担当。
#
# webhook は resource-audit と同じ探索順 (専用 env → discord-notify) で解決する。
# 未設定なら何もせず exit 0 (呼び出し側を壊さない)。

set -uo pipefail

: "${VLOGS_URL:=http://127.0.0.1:9428}"
: "${HEARTBEAT_DAYS:=7}"

if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
  for ENV_FILE in \
    "${XDG_CONFIG_HOME:-$HOME/.config}/resource-audit/env" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/discord-notify/env"; do
    # shellcheck source=/dev/null
    [ -f "$ENV_FILE" ] && . "$ENV_FILE" && break
  done
fi
WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

if [ -z "$WEBHOOK_URL" ] && [ "$DRY_RUN" -eq 0 ]; then
  echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) job=backup-heartbeat status=skip reason=\"no webhook\""
  exit 0
fi

start="$(date -u -d "${HEARTBEAT_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)"
end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# LogsQL を投げて 1 つの数値を取り出す
vl_count() {
  curl -sS --max-time 20 "$VLOGS_URL/select/logsql/stats_query" \
    --data-urlencode "query=$1" \
    --data-urlencode "start=$start" \
    --data-urlencode "end=$end" 2>/dev/null \
    | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo "?"
}

# 最後に成功した時刻
vl_last_ok() {
  curl -sS --max-time 20 "$VLOGS_URL/select/logsql/query" \
    --data-urlencode "query=$1 | sort by (_time desc) | limit 1 | fields _time" \
    --data-urlencode "start=$start" \
    --data-urlencode "end=$end" 2>/dev/null \
    | jq -r '._time // "-"' 2>/dev/null | cut -c1-16 || echo "?"
}

row() {  # row <表示名> <service.name> <job 名>
  local label="$1" svc="$2" job="$3"
  local base="{service.name=\"$svc\"} | unpack_logfmt | filter job:=$job"
  local ok fail last
  ok="$(vl_count "$base status:=ok | stats count() as n")"
  fail="$(vl_count "$base status:=error | stats count() as n")"
  last="$(vl_last_ok "$base status:=ok")"
  printf '%-12s 成功 %-3s 失敗 %-3s 最終 %s\n' "$label" "$ok" "$fail" "${last:--}"
}

body="$(
  row "L1 (~/)"    "backup-user"   "restic-user"
  row "L1 (root)"  "backup-root"   "restic-root"
  row "L3 (Drive)" "backup-l3"     "restic-l3"
  row "check"      "maintain-user" "restic-user-check"
)"

# 容量 (リポジトリと Drive の空き)。取れなければ行を出さない。
sizes=""
repo_b="$(vl_count '{service.name="maintain-user"} | unpack_logfmt | filter job:=restic-user-stats | stats max(repo_size_b) as n')"
free_b="$(vl_count '{service.name="backup-l3"} | unpack_logfmt | filter job:=restic-l3-quota | stats max(drive_free_b) as n')"
gib() { awk -v b="$1" 'BEGIN{ if (b+0>0) printf "%.2f GiB", b/1073741824; else print "-" }'; }
tib() { awk -v b="$1" 'BEGIN{ if (b+0>0) printf "%.2f TiB", b/1099511627776; else print "-" }'; }
[ "$repo_b" != "0" ] && [ "$repo_b" != "?" ] && sizes="リポジトリ $(gib "$repo_b")"
if [ "$free_b" != "0" ] && [ "$free_b" != "?" ]; then
  [ -n "$sizes" ] && sizes="$sizes / "
  sizes="${sizes}Drive 空き $(tib "$free_b")"
fi
[ -n "$sizes" ] && body="$body
$sizes"

msg="**develop バックアップ 週次 heartbeat** (直近 ${HEARTBEAT_DAYS} 日)
\`\`\`
$body
\`\`\`
この通知が届かなくなったら、バックアップか obs スタックのどちらかが止まっています。"

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s\n' "$msg"
  exit 0
fi

code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
  -H 'Content-Type: application/json' \
  -X POST "$WEBHOOK_URL" \
  --data "$(jq -nc --arg c "$msg" '{content: $c}')" 2>/dev/null)"

if [ "$code" = "204" ] || [ "$code" = "200" ]; then
  echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) job=backup-heartbeat status=ok http=$code"
else
  echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) job=backup-heartbeat status=error http=$code"
  exit 1
fi
