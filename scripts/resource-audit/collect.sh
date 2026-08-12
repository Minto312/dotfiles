#!/usr/bin/env bash
# resource-audit collector (Tier 1)
# このマシンのリソース使用状況を決定論的に測ってスナップショットに保存する。
# LLM は使わない。判断は Tier 2 (skill resource-audit) が latest/previous を読んで行う。
# 閾値を超えたものだけ、かつ「前回は超えていなかったもの」だけ Discord に通知する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/resource-audit"
TS=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="${STATE_DIR}/runs/${TS}"
LATEST_LINK="${STATE_DIR}/latest"
PREV_LINK="${STATE_DIR}/previous"
ALLOW_FILE="${RESOURCE_AUDIT_ALLOW:-${SCRIPT_DIR}/wildcard-allow.txt}"
RETAIN_DAYS="${RESOURCE_AUDIT_RETAIN_DAYS:-90}"

# webhook は discord-notify と同じものを使う (~/.config/discord-notify/env)。
# 未設定でも収集は続行する (通知だけスキップ)。
WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

DEEP=0
NOTIFY_ALL=0
for arg in "$@"; do
  case "$arg" in
    --deep) DEEP=1 ;;
    --notify-all) NOTIFY_ALL=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$RUN_DIR"
log() { printf '[%s] %s\n' "$(date -Is)" "$*" >&2; }

# herdr / claude は user の ~/.local/bin にあり、systemd timer の PATH には入らない。
export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"

UID_NUM=$(id -u)
CGROUP_USER="/sys/fs/cgroup/user.slice/user-${UID_NUM}.slice"

# ---- 1. 生データを採る ------------------------------------------------------
# 個別ファイルは Tier 2 が細部を見たいとき用。summary.json が突き合わせ用。

{
  echo "# uptime / loadavg"; uptime; cat /proc/loadavg
  echo; echo "# free -b"; free -b
  echo; echo "# meminfo (抜粋)"
  grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Dirty|Committed_AS|CommitLimit)' /proc/meminfo
  echo; echo "# swapon"; swapon --show || true
  echo; echo "# cgroup memory.stat (user slice)"
  grep -E '^(anon|file|shmem|slab|sock|kernel_stack|pgmajfault) ' "${CGROUP_USER}/memory.stat" 2>/dev/null || true
  echo; echo "# pressure"
  for f in /proc/pressure/*; do echo "-- $f"; cat "$f"; done
} > "${RUN_DIR}/memory.txt" 2>&1 || true

{
  echo "# df -B1 (tmpfs/devtmpfs 除く)"; df -B1 -x tmpfs -x devtmpfs || true
  echo; echo "# df -i"; df -i -x tmpfs -x devtmpfs || true
  echo; echo "# tmpfs (/tmp は RAM を食う)"; df -B1 -t tmpfs || true
  echo; echo "# sda io (sar)"; sar -d -p 2>/dev/null | grep -E 'Average|sda' || true
} > "${RUN_DIR}/disk.txt" 2>&1 || true

ps -eo pid,ppid,user,rss,pcpu,etimes,comm,args --sort=-rss --no-headers 2>/dev/null \
  | head -30 | cut -c1-240 > "${RUN_DIR}/processes.txt" || true

# 2 日以上生きている対話エージェント (放置検知用)
ps -eo etimes,pid,args --no-headers 2>/dev/null \
  | grep -E '(^| )(claude|codex)( |$)|bin/(claude|codex)' | grep -v grep \
  | awk '$1 > 172800 {printf "%6.1fd  pid=%s  %s\n", $1/86400, $2, substr($0, index($0,$3))}' \
  | sort -rn | cut -c1-200 > "${RUN_DIR}/long-lived-agents.txt" || true

ss -tulpnH 2>/dev/null | awk '{print $1, $5, $7}' | sort -u > "${RUN_DIR}/listeners.txt" || true

{
  echo "# system failed"; systemctl --failed --no-pager --no-legend 2>/dev/null || true
  echo "# user failed"; systemctl --user --failed --no-pager --no-legend 2>/dev/null || true
  echo; echo "# user timers"; systemctl --user list-timers --all --no-pager --no-legend 2>/dev/null | cut -c1-140 || true
} > "${RUN_DIR}/units.txt" 2>&1 || true

herdr agent list 2>/dev/null > "${RUN_DIR}/herdr-agents.json" || echo '{}' > "${RUN_DIR}/herdr-agents.json"

docker system df 2>/dev/null > "${RUN_DIR}/docker.txt" || true

# --deep はディスクの内訳まで見る (du は重いので週次だけ)
if [ "$DEEP" = 1 ]; then
  mkdir -p "${RUN_DIR}/deep"
  du -xh -d1 "$HOME" 2>/dev/null | sort -h | tail -25 > "${RUN_DIR}/deep/home.txt" || true
  du -xh -d1 "$HOME/workspace" "$HOME/programs" 2>/dev/null | sort -h | tail -40 > "${RUN_DIR}/deep/projects.txt" || true
  du -xh -d1 /tmp 2>/dev/null | sort -h | tail -20 > "${RUN_DIR}/deep/tmp.txt" || true
  for pat in node_modules target .venv .next; do
    find "$HOME/programs" "$HOME/workspace" -maxdepth 6 -type d -name "$pat" -prune 2>/dev/null \
      | xargs -r -d '\n' du -xsb 2>/dev/null \
      | awk -v p="$pat" '{s+=$1; n++} END {printf "%-14s %4d dirs  %8.2f GiB\n", p, n, s/1073741824}'
  done > "${RUN_DIR}/deep/reclaimable.txt" 2>/dev/null || true
fi

# ---- 2. 主要指標を数値化 ----------------------------------------------------
read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
CORES=$(nproc)

mi() { awk -v k="$1" '$1 == k":" {print $2 * 1024; found=1} END {if (!found) print 0}' /proc/meminfo; }
MEM_TOTAL=$(mi MemTotal); MEM_AVAIL=$(mi MemAvailable)
SWAP_TOTAL=$(mi SwapTotal); SWAP_FREE=$(mi SwapFree)
MEM_USED=$((MEM_TOTAL - MEM_AVAIL))
SWAP_USED=$((SWAP_TOTAL - SWAP_FREE))

cg() { awk -v k="$1" '$1 == k {print $2; found=1} END {if (!found) print 0}' "${CGROUP_USER}/memory.stat" 2>/dev/null || echo 0; }
MEM_ANON=$(cg anon); MEM_SHMEM=$(cg shmem)

psi_full() { awk '/^full/ {for (i=1; i<=NF; i++) if ($i ~ /^avg300=/) {sub(/avg300=/, "", $i); print $i; found=1}} END {if (!found) print 0}' "/proc/pressure/$1" 2>/dev/null || echo 0; }
PSI_CPU=$(psi_full cpu); PSI_IO=$(psi_full io); PSI_MEM=$(psi_full memory)

DISK_TOTAL=$(df -B1 --output=size / | tail -1 | tr -d ' ')
DISK_USED=$(df -B1 --output=used / | tail -1 | tr -d ' ')
DISK_PCT=$(df --output=pcent / | tail -1 | tr -d ' %')
INODE_PCT=$(df --output=ipcent / | tail -1 | tr -d ' %')
TMP_USED=$(df -B1 --output=used /tmp 2>/dev/null | tail -1 | tr -d ' ' || echo 0)

PROC_TOTAL=$(ps -e --no-headers 2>/dev/null | wc -l)
THREADS=$(ps -eLf --no-headers 2>/dev/null | wc -l)

# RSS 合計は args 全体で引っかける (bg-pty-host / MCP の node も数える)
agg() { ps -eo rss,args --no-headers 2>/dev/null | grep -F "$1" | grep -v grep \
  | awk '{n++; s+=$1} END {printf "%d %d\n", n+0, (s+0)*1024}'; }
read -r CLAUDE_N CLAUDE_RSS < <(agg claude)
read -r CODEX_N CODEX_RSS < <(agg codex)
read -r NODE_N NODE_RSS < <(agg node)

AGENT_TOTAL=$(jq -r '.result.agents | length // 0' "${RUN_DIR}/herdr-agents.json" 2>/dev/null || echo 0)
astat() { jq -r --arg s "$1" '[.result.agents[]? | select(.agent_status == $s)] | length' "${RUN_DIR}/herdr-agents.json" 2>/dev/null || echo 0; }
A_IDLE=$(astat idle); A_WORKING=$(astat working); A_BLOCKED=$(astat blocked); A_DONE=$(astat done)

OLDEST_DAYS=$(awk 'NR==1 {sub(/d$/, "", $1); print $1+0; found=1} END {if (!found) print 0}' "${RUN_DIR}/long-lived-agents.txt" 2>/dev/null || echo 0)

# ワイルドカード待ち受けのうち、許可リストに無いポート
touch "$ALLOW_FILE" 2>/dev/null || true
WILDCARD=$(awk '$2 ~ /^(0\.0\.0\.0|\[::\]):/ {n=split($2, a, ":"); print a[n]}' "${RUN_DIR}/listeners.txt" 2>/dev/null | sort -u \
  | grep -vxF -f <(grep -vE '^\s*(#|$)' "$ALLOW_FILE" 2>/dev/null | awk '{print $1}') 2>/dev/null || true)

# --failed の行頭には "●" が付くので $1 決め打ちでは取れない。unit 名らしいフィールドを拾う。
# (list-timers 節まで拾わないよう、failed の 2 節だけを対象にする)
FAILED_UNITS=$(awk '
    /^# user timers/ {exit}
    /^# /            {next}
    {for (i = 1; i <= NF; i++) if ($i ~ /\.(service|timer|socket|mount|path)$/) {print $i; break}}
  ' "${RUN_DIR}/units.txt" 2>/dev/null | sort -u || true)

REBOOT=false; REBOOT_AGE=0
if [ -f /var/run/reboot-required ]; then
  REBOOT=true
  REBOOT_AGE=$(( ( $(date +%s) - $(stat -c %Y /var/run/reboot-required) ) / 86400 ))
fi

jq -n \
  --arg ts "$TS" --arg host "$(hostname)" --arg kernel "$(uname -r)" \
  --argjson uptime "$(awk '{printf "%d", $1}' /proc/uptime)" \
  --argjson cores "$CORES" --argjson l1 "$LOAD1" --argjson l5 "$LOAD5" --argjson l15 "$LOAD15" \
  --argjson mt "$MEM_TOTAL" --argjson ma "$MEM_AVAIL" --argjson mu "$MEM_USED" \
  --argjson man "$MEM_ANON" --argjson msh "$MEM_SHMEM" \
  --argjson st "$SWAP_TOTAL" --argjson su "$SWAP_USED" \
  --argjson pc "$PSI_CPU" --argjson pi "$PSI_IO" --argjson pm "$PSI_MEM" \
  --argjson dt "$DISK_TOTAL" --argjson du_ "$DISK_USED" --argjson dp "$DISK_PCT" --argjson ip "$INODE_PCT" \
  --argjson tu "$TMP_USED" \
  --argjson pt "$PROC_TOTAL" --argjson th "$THREADS" \
  --argjson cn "$CLAUDE_N" --argjson cr "$CLAUDE_RSS" --argjson xn "$CODEX_N" --argjson xr "$CODEX_RSS" \
  --argjson nn "$NODE_N" --argjson nr "$NODE_RSS" \
  --argjson at "$AGENT_TOTAL" --argjson ai "$A_IDLE" --argjson aw "$A_WORKING" \
  --argjson ab "$A_BLOCKED" --argjson ad "$A_DONE" --argjson od "$OLDEST_DAYS" \
  --arg wildcard "$WILDCARD" --arg failed "$FAILED_UNITS" \
  --argjson reboot "$REBOOT" --argjson rage "$REBOOT_AGE" --argjson deep "$DEEP" \
  '{
    ts: $ts, host: $host, kernel: $kernel, uptime_seconds: $uptime, deep: ($deep == 1),
    cpu: {cores: $cores, load1: $l1, load5: $l5, load15: $l15},
    mem: {total_bytes: $mt, available_bytes: $ma, used_bytes: $mu, anon_bytes: $man, shmem_bytes: $msh},
    swap: {total_bytes: $st, used_bytes: $su},
    pressure_full_avg300: {cpu: $pc, io: $pi, memory: $pm},
    disk: {root_total_bytes: $dt, root_used_bytes: $du_, root_use_pct: $dp, root_inode_pct: $ip, tmp_used_bytes: $tu},
    procs: {total: $pt, threads: $th,
            claude: $cn, claude_rss_bytes: $cr, codex: $xn, codex_rss_bytes: $xr,
            node: $nn, node_rss_bytes: $nr},
    agents: {total: $at, idle: $ai, working: $aw, blocked: $ab, done: $ad, oldest_days: $od},
    wildcard_listeners: ($wildcard | split("\n") | map(select(length > 0))),
    failed_units: ($failed | split("\n") | map(select(length > 0))),
    reboot: {required: $reboot, age_days: $rage}
  }' > "${RUN_DIR}/summary.json"

# ---- 3. 閾値評価 -----------------------------------------------------------
# 1 行 1 アラート。キーは「同じ状態が続く限り同じ文字列」になるようにして、
# 前回との差分で「新規に悪化したものだけ」を通知する (dns-dangling-monitor と同じ流儀)。
ALERTS="${RUN_DIR}/alerts.txt"
: > "$ALERTS"
gt() { awk -v a="$1" -v b="$2" 'BEGIN {exit !(a > b)}'; }

gt "$DISK_PCT" 85       && echo "disk-root	/ が ${DISK_PCT}% (閾値 85%)" >> "$ALERTS" || true
gt "$INODE_PCT" 85      && echo "disk-inode	inode が ${INODE_PCT}% (閾値 85%)" >> "$ALERTS" || true
gt "$SWAP_USED" 268435456 && echo "swap-used	swap を $((SWAP_USED / 1048576)) MiB 使用 (通常 0)" >> "$ALERTS" || true
gt 4294967296 "$MEM_AVAIL" && echo "mem-low	available が $((MEM_AVAIL / 1048576)) MiB (閾値 4096 MiB)" >> "$ALERTS" || true
gt "$PSI_MEM" 0.1       && echo "psi-memory	memory pressure full avg300=${PSI_MEM} (通常 0)" >> "$ALERTS" || true
gt "$PSI_IO" 1.0        && echo "psi-io	io pressure full avg300=${PSI_IO}" >> "$ALERTS" || true
gt "$PSI_CPU" 1.0       && echo "psi-cpu	cpu pressure full avg300=${PSI_CPU}" >> "$ALERTS" || true
gt "$TMP_USED" 8589934592 && echo "tmp-large	/tmp (tmpfs=RAM) が $((TMP_USED / 1073741824)) GiB" >> "$ALERTS" || true
gt "$OLDEST_DAYS" 14    && echo "agent-stale	最古のエージェントが ${OLDEST_DAYS} 日生存" >> "$ALERTS" || true
if [ "$REBOOT" = true ] && [ "$REBOOT_AGE" -gt 7 ]; then
  echo "reboot-pending	再起動待ちが ${REBOOT_AGE} 日 (稼働カーネル $(uname -r))" >> "$ALERTS"
fi
for u in $FAILED_UNITS; do echo "unit-failed:${u}	${u} が failed" >> "$ALERTS"; done
for p in $WILDCARD; do echo "listener:${p}	0.0.0.0:${p} が待ち受け中 (許可リスト外)" >> "$ALERTS"; done

# ---- 4. symlink 更新 + 保持期間 --------------------------------------------
if [ -L "$LATEST_LINK" ]; then
  ln -sfn "$(readlink "$LATEST_LINK")" "$PREV_LINK"
fi
ln -sfn "$RUN_DIR" "$LATEST_LINK"

# 自分がディスクを食う側にならないよう古い run を落とす
find "${STATE_DIR}/runs" -mindepth 1 -maxdepth 1 -type d -mtime "+${RETAIN_DAYS}" -exec rm -rf {} + 2>/dev/null || true

# ---- 5. 新規アラートだけ通知 -----------------------------------------------
PREV_ALERTS="${PREV_LINK}/alerts.txt"
if [ "$NOTIFY_ALL" = 1 ] || [ ! -f "$PREV_ALERTS" ]; then
  NEW=$(cut -f1 "$ALERTS" | sort -u || true)
else
  NEW=$(comm -13 <(cut -f1 "$PREV_ALERTS" | sort -u) <(cut -f1 "$ALERTS" | sort -u) || true)
fi

if [ -z "$NEW" ]; then
  log "no new alerts ($(wc -l < "$ALERTS") active)"
  exit 0
fi

BODY=$(while IFS= read -r key; do
  [ -z "$key" ] && continue
  awk -F'\t' -v k="$key" '$1 == k {print "・" $2}' "$ALERTS"
done <<< "$NEW")

log "new alerts:"; printf '%s\n' "$BODY" >&2

if [ -z "$WEBHOOK_URL" ]; then
  log "DISCORD_WEBHOOK_URL 未設定のため通知はスキップした"
  exit 0
fi

MSG=$(printf '**[resource-audit] %s で新たに閾値を超えました**\n%s\n\n`/resource-audit` で詳細レポートを出せます。' "$(hostname)" "$BODY")
jq -n --arg c "$MSG" '{content: $c}' \
  | curl -sS -H 'Content-Type: application/json' -X POST -d @- "$WEBHOOK_URL" >/dev/null \
  && log "notified discord" || log "discord 通知に失敗した"
