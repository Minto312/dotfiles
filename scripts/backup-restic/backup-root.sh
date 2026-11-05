#!/usr/bin/env bash
# develop の root 領域を restic で個人 Google Drive へバックアップする (L1 / root 側)。
# root の systemd system unit から実行する。
#
# 2026-11-05 から Google Drive (gdrive:restic/develop-root) へ直送している。
# それまでは pve (自宅) へ SFTP で送っていて、root 側は Drive へ複製していなかった。
# develop を浜松オフィスへ移して pve に届かなくなったので、Drive に新しく repo を作った
# (pve 側の旧 repo の履歴は引き継いでいない)。rclone の serve だけは karinto で動かす
# (rclone-serve.sh の RCLONE_RUN_AS)。
#
# 対象:
#   /etc                     ネットワーク・system unit・各種設定
#   /var/lib/docker/volumes  🔴 Grafana の dashboard/alert/silence の唯一の実体
#   /var/lib/tailscale       ノード鍵 (develop 本体 = SaaS 側の tailnet)
#   /var/spool/cron
#   /root
#   ~/workspace/raim-tailnet-proxy/state
#     🔴 raim tailnet (headscale) の node key。コンテナの bind mount なので
#        /var/lib/docker/volumes には入らず、中身が root 所有なので
#        karinto で走る L1 (user) からも読めない。ここで拾わないと
#        L1 でも L3 でもどこにも残らない (backup-develop.md §0.5)。
#
# 設計: machine/storage/backup-develop.md §4.2

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# RESTIC_REPOSITORY を渡さなければ、REPO_RCLONE_PATH を rclone serve 越しに使う
: "${REPO_RCLONE_PATH:=gdrive:restic/develop-root}"
: "${RCLONE_RUN_AS:=karinto}"
: "${RESTIC_PASSWORD_FILE:=/root/.restic/develop-root.pass}"
: "${RESTIC_CACHE_DIR:=/var/cache/restic}"
: "${BACKUP_EXCLUDES:=$SCRIPT_DIR/excludes-root.txt}"
: "${BACKUP_TAG:=root}"
: "${KEEP_DAILY:=7}"
: "${KEEP_WEEKLY:=4}"
: "${KEEP_MONTHLY:=6}"
export RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR RCLONE_RUN_AS

TARGETS=(/etc /var/lib/docker/volumes /var/lib/tailscale /var/spool/cron /root
         /home/karinto/workspace/raim-tailnet-proxy/state)

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
# shellcheck source=rclone-serve.sh
. "$SCRIPT_DIR/rclone-serve.sh"
trap 'rm -f "$tmp_json" "$tmp_json.err"; stop_rclone_serve' EXIT

if [ -z "${RESTIC_REPOSITORY:-}" ]; then
  RCLONE="$(getent passwd "$RCLONE_RUN_AS" | cut -d: -f6)/.local/bin/rclone"
  [ -x "$RCLONE" ] || RCLONE="$(command -v rclone)" || { echo "ts=$(now_iso) job=restic-$BACKUP_TAG status=error reason=\"rclone not found\""; exit 1; }
  start_rclone_serve "$REPO_RCLONE_PATH" "restic-$BACKUP_TAG" || exit 1
  RESTIC_REPOSITORY="$REST_REPO"
fi
export RESTIC_REPOSITORY

start_ts=$(date +%s)
"$RESTIC" backup "${REPO_OPTS[@]}" \
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
  "$RESTIC" forget "${REPO_OPTS[@]}" --tag "$BACKUP_TAG" \
    --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" \
    >/dev/null 2>&1
  f_rc=$?
  printf 'ts=%s job=restic-%s-forget status=%s rc=%s duration_s=%s\n' \
    "$(now_iso)" "$BACKUP_TAG" "$([ $f_rc -eq 0 ] && echo ok || echo error)" "$f_rc" "$(($(date +%s) - s))"
fi

# 週の初めだけ prune + check (Drive では prune が download + reupload になるので重い)
if [ "$(date +%u)" = "7" ]; then
  s=$(date +%s)
  "$RESTIC" forget "${REPO_OPTS[@]}" --tag "$BACKUP_TAG" \
    --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" \
    --prune >/dev/null 2>&1
  p_rc=$?
  "$RESTIC" check "${REPO_OPTS[@]}" >/dev/null 2>&1
  c_rc=$?
  printf 'ts=%s job=restic-%s-maintain status=%s prune_rc=%s check_rc=%s duration_s=%s\n' \
    "$(now_iso)" "$BACKUP_TAG" "$([ $p_rc -eq 0 ] && [ $c_rc -eq 0 ] && echo ok || echo error)" \
    "$p_rc" "$c_rc" "$(($(date +%s) - s))"
fi

exit "$rc"
