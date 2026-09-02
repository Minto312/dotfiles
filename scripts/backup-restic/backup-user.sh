#!/usr/bin/env bash
# develop の ~ を restic で pve へバックアップする (L1 / user 側)。
#
# 方針: このスクリプトは「測定するだけ」。判定も通知もしない。
#   logfmt を stdout に吐き、journald -> Alloy -> VictoriaLogs -> Grafana Alerting が判定する。
#   (services/domain-monitor.md と同じ構造)
#
# 設計: machine/storage/backup-develop.md §4.2

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 設定 (env で上書き可) ---
: "${RESTIC_REPOSITORY:=sftp:pve-backup:/rpool/backup/develop-restic}"
: "${RESTIC_PASSWORD_FILE:=$HOME/.local/state/restic/develop-user.pass}"
: "${RESTIC_CACHE_DIR:=$HOME/.cache/restic}"
: "${BACKUP_TARGET:=$HOME}"
: "${BACKUP_EXCLUDES:=$SCRIPT_DIR/excludes-user.txt}"
: "${BACKUP_TAG:=user}"
: "${KEEP_DAILY:=7}"
: "${KEEP_WEEKLY:=4}"
: "${KEEP_MONTHLY:=6}"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR

# systemd の PATH には ~/.local/bin が無い (services/feedscope.md の既知の罠)
resolve_bin() {
  local name="$1" p
  for p in "$HOME/.local/bin/$name" "/usr/local/bin/$name" "/usr/bin/$name"; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  command -v "$name" 2>/dev/null && return 0
  return 1
}

RESTIC="$(resolve_bin restic)" || { echo "job=restic-$BACKUP_TAG status=error reason=\"restic not found\""; exit 1; }
JQ="$(resolve_bin jq)" || JQ=""

log() { printf '%s\n' "$*"; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

start_ts=$(date +%s)

if [ ! -s "$RESTIC_PASSWORD_FILE" ]; then
  log "ts=$(now_iso) job=restic-$BACKUP_TAG status=error reason=\"password file missing\" path=$RESTIC_PASSWORD_FILE"
  exit 1
fi

tmp_json="$(mktemp -t restic-backup-XXXXXX.json)"
trap 'rm -f "$tmp_json"' EXIT

# --- backup ---
#   --one-file-system : /home 配下に他のマウントは無いことを確認済み
#   --exclude-caches  : CACHEDIR.TAG を持つディレクトリを自動で外す
"$RESTIC" backup \
  --json \
  --tag "$BACKUP_TAG" \
  --one-file-system \
  --exclude-caches \
  --exclude-file "$BACKUP_EXCLUDES" \
  "$BACKUP_TARGET" > "$tmp_json" 2>"$tmp_json.err"
rc=$?

end_ts=$(date +%s)
dur=$((end_ts - start_ts))

# restic の終了コード:
#   0 = 成功 / 1 = 失敗 / 3 = 一部のファイルを読めなかった (部分成功)
case "$rc" in
  0) status=ok ;;
  3) status=warn ;;
  *) status=error ;;
esac

line="ts=$(now_iso) job=restic-$BACKUP_TAG status=$status rc=$rc duration_s=$dur"

if [ -n "$JQ" ] && [ -s "$tmp_json" ]; then
  summary="$("$JQ" -c 'select(.message_type=="summary")' < "$tmp_json" | tail -1)"
  if [ -n "$summary" ]; then
    read -r files_new files_changed files_unmodified data_added data_added_packed total_files total_bytes snap_id <<EOF
$(printf '%s' "$summary" | "$JQ" -r '[.files_new, .files_changed, .files_unmodified, .data_added, (.data_added_packed // 0), .total_files_processed, .total_bytes_processed, (.snapshot_id // "-")] | @tsv')
EOF
    line="$line files_new=$files_new files_changed=$files_changed files_unmodified=$files_unmodified"
    line="$line data_added_b=$data_added data_added_packed_b=$data_added_packed"
    line="$line total_files=$total_files total_bytes=$total_bytes snapshot=$snap_id"
  fi
fi

if [ "$status" != "ok" ]; then
  err="$(tail -3 "$tmp_json.err" 2>/dev/null | tr '\n' ' ' | tr -d '"' | cut -c1-300)"
  line="$line error=\"$err\""
fi
rm -f "$tmp_json.err"

log "$line"

# --- forget (prune はしない。重いので maintain-user.sh の担当) ---
if [ "$status" != "error" ]; then
  f_start=$(date +%s)
  f_out="$("$RESTIC" forget \
    --tag "$BACKUP_TAG" \
    --keep-daily "$KEEP_DAILY" \
    --keep-weekly "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY" 2>&1)"
  f_rc=$?
  f_dur=$(($(date +%s) - f_start))
  log "ts=$(now_iso) job=restic-$BACKUP_TAG-forget status=$([ $f_rc -eq 0 ] && echo ok || echo error) rc=$f_rc duration_s=$f_dur"
fi

exit "$rc"
