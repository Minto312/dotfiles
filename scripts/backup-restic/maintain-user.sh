#!/usr/bin/env bash
# L1 リポジトリの保守 (週次)。prune と check を担当する。
#
# backup-user.sh から分けている理由:
#   prune / check --read-data は重い。2026-11-05 にリポジトリを Google Drive へ移してからは
#   prune が download + reupload になり、check --read-data も実データを落としてくる。
#   日次の backup と同じ時間帯に走らせない (machine/storage/backup-develop.md §4.2)。
#
# 毎週: forget --prune + check (メタデータのみ)
# 毎月 (第 1 週): さらに check --read-data-subset で実データの一部を検証する

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# RESTIC_REPOSITORY を渡さなければ、REPO_RCLONE_PATH を rclone serve 越しに使う (backup-user.sh と同じ)
: "${REPO_RCLONE_PATH:=gdrive:restic/develop-user}"
: "${RESTIC_PASSWORD_FILE:=$HOME/.local/state/restic/develop-user.pass}"
: "${RESTIC_CACHE_DIR:=$HOME/.cache/restic}"
: "${BACKUP_TAG:=user}"
: "${KEEP_DAILY:=7}"
: "${KEEP_WEEKLY:=4}"
: "${KEEP_MONTHLY:=6}"
: "${READ_DATA_SUBSET:=1/8}"
export RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR

resolve_bin() {
  local name="$1" p
  for p in "$HOME/.local/bin/$name" "/usr/local/bin/$name" "/usr/bin/$name"; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  command -v "$name" 2>/dev/null && return 0
  return 1
}
RESTIC="$(resolve_bin restic)" || { echo "job=restic-$BACKUP_TAG-maintain status=error reason=\"restic not found\""; exit 1; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
JQ="$(resolve_bin jq)" || JQ=""

# shellcheck source=rclone-serve.sh
. "$SCRIPT_DIR/rclone-serve.sh"
trap stop_rclone_serve EXIT
if [ -z "${RESTIC_REPOSITORY:-}" ]; then
  RCLONE="$(resolve_bin rclone)" || { echo "ts=$(now_iso) job=restic-$BACKUP_TAG-maintain status=error reason=\"rclone not found\""; exit 1; }
  start_rclone_serve "$REPO_RCLONE_PATH" "restic-$BACKUP_TAG-maintain" || exit 1
  RESTIC_REPOSITORY="$REST_REPO"
fi
export RESTIC_REPOSITORY

# 🔴 rc=11 は「リポジトリのロックに失敗」。中断されたジョブが残したロックが
#    原因のことが多い。`restic unlock` は既定で stale なロックしか消さないので、
#    1 回だけ解除して retry する。
run_step() {
  local name="$1"; shift
  local s e rc out
  s=$(date +%s)
  out="$("$@" 2>&1)"; rc=$?
  if [ $rc -eq 11 ]; then
    "$RESTIC" unlock "${REPO_OPTS[@]}" >/dev/null 2>&1
    out="$("$@" 2>&1)"; rc=$?
  fi
  e=$(date +%s)
  local line="ts=$(now_iso) job=restic-$BACKUP_TAG-$name status=$([ $rc -eq 0 ] && echo ok || echo error) rc=$rc duration_s=$((e - s))"
  if [ $rc -ne 0 ]; then
    line="$line error=\"$(printf '%s' "$out" | tail -3 | tr '\n' ' ' | tr -d '"' | cut -c1-300)\""
  fi
  printf '%s\n' "$line"
  return $rc
}

overall=0

run_step prune "$RESTIC" forget "${REPO_OPTS[@]}" \
  --tag "$BACKUP_TAG" \
  --keep-daily "$KEEP_DAILY" \
  --keep-weekly "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY" \
  --prune || overall=1

run_step check "$RESTIC" check "${REPO_OPTS[@]}" || overall=1

# 月初の週だけ実データの一部を読む
day=$(date +%-d)
if [ "$day" -le 7 ]; then
  run_step check-data "$RESTIC" check "${REPO_OPTS[@]}" --read-data-subset="$READ_DATA_SUBSET" || overall=1
fi

# リポジトリの現況を 1 行で残す (Grafana から容量を追える)
stats="$("$RESTIC" stats "${REPO_OPTS[@]}" --mode raw-data --json 2>/dev/null)"
if [ -n "$stats" ]; then
  if [ -n "$JQ" ]; then
    read -r total_size total_blob <<EOF
$(printf '%s' "$stats" | "$JQ" -r '[.total_size, .total_blob_count] | @tsv')
EOF
    snaps="$("$RESTIC" snapshots "${REPO_OPTS[@]}" --json 2>/dev/null | "$JQ" 'length' 2>/dev/null)"
    printf 'ts=%s job=restic-%s-stats status=ok repo_size_b=%s blobs=%s snapshots=%s\n' \
      "$(now_iso)" "$BACKUP_TAG" "$total_size" "$total_blob" "${snaps:-0}"
  fi
fi

# Drive の空き (heartbeat が読む)。Drive に置いているときだけ
if [ -n "${RCLONE:-}" ] && [ -n "$JQ" ]; then
  about="$("$RCLONE" about "${REPO_RCLONE_PATH%%:*}:" --json 2>/dev/null)"
  if [ -n "$about" ]; then
    read -r d_total d_used d_free <<EOF
$(printf '%s' "$about" | "$JQ" -r '[(.total // 0), (.used // 0), (.free // 0)] | @tsv')
EOF
    printf 'ts=%s job=restic-%s-quota status=ok drive_total_b=%s drive_used_b=%s drive_free_b=%s\n' \
      "$(now_iso)" "$BACKUP_TAG" "$d_total" "$d_used" "$d_free"
  fi
fi

exit "$overall"
