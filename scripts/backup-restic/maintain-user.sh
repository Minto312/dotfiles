#!/usr/bin/env bash
# L1 リポジトリの保守 (週次)。prune と check を担当する。
#
# backup-user.sh から分けている理由:
#   pve のディスクは 2.5" 5400rpm の RAIDZ1 なので prune / check --read-data が重い。
#   日次の backup と同じ時間帯に走らせない (machine/storage/backup-develop.md §4.2)。
#
# 毎週: forget --prune + check (メタデータのみ)
# 毎月 (第 1 週): さらに check --read-data-subset で実データの一部を検証する

set -uo pipefail

: "${RESTIC_REPOSITORY:=sftp:pve-backup:/rpool/backup/develop-restic}"
: "${RESTIC_PASSWORD_FILE:=$HOME/.local/state/restic/develop-user.pass}"
: "${RESTIC_CACHE_DIR:=$HOME/.cache/restic}"
: "${BACKUP_TAG:=user}"
: "${KEEP_DAILY:=7}"
: "${KEEP_WEEKLY:=4}"
: "${KEEP_MONTHLY:=6}"
: "${READ_DATA_SUBSET:=1/8}"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR

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

run_step() {
  local name="$1"; shift
  local s e rc out
  s=$(date +%s)
  out="$("$@" 2>&1)"; rc=$?
  e=$(date +%s)
  local line="ts=$(now_iso) job=restic-$BACKUP_TAG-$name status=$([ $rc -eq 0 ] && echo ok || echo error) rc=$rc duration_s=$((e - s))"
  if [ $rc -ne 0 ]; then
    line="$line error=\"$(printf '%s' "$out" | tail -3 | tr '\n' ' ' | tr -d '"' | cut -c1-300)\""
  fi
  printf '%s\n' "$line"
  return $rc
}

overall=0

run_step prune "$RESTIC" forget \
  --tag "$BACKUP_TAG" \
  --keep-daily "$KEEP_DAILY" \
  --keep-weekly "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY" \
  --prune || overall=1

run_step check "$RESTIC" check || overall=1

# 月初の週だけ実データの一部を読む
day=$(date +%-d)
if [ "$day" -le 7 ]; then
  run_step check-data "$RESTIC" check --read-data-subset="$READ_DATA_SUBSET" || overall=1
fi

# リポジトリの現況を 1 行で残す (Grafana から容量を追える)
stats="$("$RESTIC" stats --mode raw-data --json 2>/dev/null)"
if [ -n "$stats" ]; then
  JQ="$(resolve_bin jq)" || JQ=""
  if [ -n "$JQ" ]; then
    read -r total_size total_blob <<EOF
$(printf '%s' "$stats" | "$JQ" -r '[.total_size, .total_blob_count] | @tsv')
EOF
    snaps="$("$RESTIC" snapshots --json 2>/dev/null | "$JQ" 'length' 2>/dev/null)"
    printf 'ts=%s job=restic-%s-stats status=ok repo_size_b=%s blobs=%s snapshots=%s\n' \
      "$(now_iso)" "$BACKUP_TAG" "$total_size" "$total_blob" "${snaps:-0}"
  fi
fi

exit "$overall"
