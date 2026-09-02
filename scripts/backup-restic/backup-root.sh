#!/usr/bin/env bash
# develop の root 領域を restic で pve へバックアップする (L1 / root 側)。
# root の systemd system unit から実行する。
#
# 対象:
#   /etc                     ネットワーク・system unit・各種設定
#   /var/lib/docker/volumes  🔴 Grafana の dashboard/alert/silence の唯一の実体
#   /var/lib/tailscale       ノード鍵
#   /var/spool/cron
#   /root
#
# 設計: machine/storage/backup-develop.md §4.2

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${RESTIC_REPOSITORY:=sftp:pve-backup:/rpool/backup/develop-root}"
: "${RESTIC_PASSWORD_FILE:=/root/.restic/develop-root.pass}"
: "${RESTIC_CACHE_DIR:=/var/cache/restic}"
: "${BACKUP_EXCLUDES:=$SCRIPT_DIR/excludes-root.txt}"
: "${BACKUP_TAG:=root}"
: "${KEEP_DAILY:=7}"
: "${KEEP_WEEKLY:=4}"
: "${KEEP_MONTHLY:=6}"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR

TARGETS=(/etc /var/lib/docker/volumes /var/lib/tailscale /var/spool/cron /root)

RESTIC=/usr/local/bin/restic
[ -x "$RESTIC" ] || RESTIC="$(command -v restic)" || { echo "job=restic-root status=error reason=\"restic not found\""; exit 1; }
JQ="$(command -v jq 2>/dev/null || true)"

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

if [ ! -s "$RESTIC_PASSWORD_FILE" ]; then
  echo "ts=$(now_iso) job=restic-$BACKUP_TAG status=error reason=\"password file missing\" path=$RESTIC_PASSWORD_FILE"
  exit 1
fi

existing=()
for t in "${TARGETS[@]}"; do [ -e "$t" ] && existing+=("$t"); done

tmp_json="$(mktemp -t restic-root-XXXXXX.json)"
trap 'rm -f "$tmp_json" "$tmp_json.err"' EXIT

start_ts=$(date +%s)
"$RESTIC" backup \
  --json \
  --tag "$BACKUP_TAG" \
  --one-file-system \
  --exclude-caches \
  --exclude-file "$BACKUP_EXCLUDES" \
  "${existing[@]}" > "$tmp_json" 2>"$tmp_json.err"
rc=$?
dur=$(($(date +%s) - start_ts))

case "$rc" in
  0) status=ok ;;
  3) status=warn ;;
  *) status=error ;;
esac

line="ts=$(now_iso) job=restic-$BACKUP_TAG status=$status rc=$rc duration_s=$dur"
if [ -n "$JQ" ] && [ -s "$tmp_json" ]; then
  summary="$("$JQ" -c 'select(.message_type=="summary")' < "$tmp_json" | tail -1)"
  if [ -n "$summary" ]; then
    read -r files_new files_changed data_added total_files total_bytes snap_id <<EOF
$(printf '%s' "$summary" | "$JQ" -r '[.files_new, .files_changed, .data_added, .total_files_processed, .total_bytes_processed, (.snapshot_id // "-")] | @tsv')
EOF
    line="$line files_new=$files_new files_changed=$files_changed data_added_b=$data_added"
    line="$line total_files=$total_files total_bytes=$total_bytes snapshot=$snap_id"
  fi
fi
if [ "$status" != "ok" ]; then
  line="$line error=\"$(tail -3 "$tmp_json.err" 2>/dev/null | tr '\n' ' ' | tr -d '"' | cut -c1-300)\""
fi
printf '%s\n' "$line"

if [ "$status" != "error" ]; then
  s=$(date +%s)
  "$RESTIC" forget --tag "$BACKUP_TAG" \
    --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" \
    >/dev/null 2>&1
  f_rc=$?
  printf 'ts=%s job=restic-%s-forget status=%s rc=%s duration_s=%s\n' \
    "$(now_iso)" "$BACKUP_TAG" "$([ $f_rc -eq 0 ] && echo ok || echo error)" "$f_rc" "$(($(date +%s) - s))"
fi

# 週の初めだけ prune + check (HDD なので重い)
if [ "$(date +%u)" = "7" ]; then
  s=$(date +%s)
  "$RESTIC" forget --tag "$BACKUP_TAG" \
    --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" \
    --prune >/dev/null 2>&1
  p_rc=$?
  "$RESTIC" check >/dev/null 2>&1
  c_rc=$?
  printf 'ts=%s job=restic-%s-maintain status=%s prune_rc=%s check_rc=%s duration_s=%s\n' \
    "$(now_iso)" "$BACKUP_TAG" "$([ $p_rc -eq 0 ] && [ $c_rc -eq 0 ] && echo ok || echo error)" \
    "$p_rc" "$c_rc" "$(($(date +%s) - s))"
fi

exit "$rc"
