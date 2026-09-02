#!/usr/bin/env bash
# L3: L1 リポジトリ (pve) を個人 Google Drive へ複製する。
#
# 目的は火事・盗難・落雷。core12400 と pve は同じ家の同じ部屋にあるので、
# L1/L2 だけでは家ごと失われる (machine/storage/backup-develop.md §9)。
#
# restic copy を使うので L3 は L1 と同じ形式・同じパスワード。
# init 時に --copy-chunker-params を渡してあるので重複排除が効く。
#
# 🔴 restic の rclone バックエンド (`rclone:` URL) は使わない。
#    それは内部で `rclone serve restic --stdio` を起動し、全リクエストが
#    1 本のパイプ上で直列化されるため、実測で 110 KiB/s しか出ない。
#    loopback の HTTP で serve して REST バックエンドから叩くと 5.1 MiB/s (46 倍)。
#
# 🔴 rclone の共有 client_id は 2026 年中に廃止される。
#    専用 client_id への移行が必要 (machine/storage/backup-develop.md §4.6)。

set -uo pipefail

: "${L1_REPO:=sftp:pve-backup:/rpool/backup/develop-restic}"
# 🔴 scope=drive.file は「その OAuth クライアント自身が作ったファイル」しか見えない。
#    client_id を差し替えると旧 client が作った repo は見えなくなるので、
#    client_id を変えるときは repo を作り直すこと (旧パスは手で消す)。
: "${L3_RCLONE_PATH:=gdrive:restic/develop-user}"
: "${RESTIC_PASSWORD_FILE:=$HOME/.local/state/restic/develop-user.pass}"
: "${RESTIC_CACHE_DIR:=$HOME/.cache/restic}"
: "${BACKUP_TAG:=user}"
: "${KEEP_DAILY:=7}"
: "${KEEP_WEEKLY:=4}"
: "${KEEP_MONTHLY:=6}"
: "${REST_CONNECTIONS:=8}"
# 18080 は別の (正体不明の loopback) サービスが使っていたので既定から外している
: "${PORT_RANGE_START:=18091}"
export RESTIC_CACHE_DIR

resolve_bin() {
  local name="$1" p
  for p in "$HOME/.local/bin/$name" "/usr/local/bin/$name" "/usr/bin/$name"; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  command -v "$name" 2>/dev/null && return 0
  return 1
}
RESTIC="$(resolve_bin restic)" || { echo "job=restic-l3 status=error reason=\"restic not found\""; exit 1; }
RCLONE="$(resolve_bin rclone)" || { echo "job=restic-l3 status=error reason=\"rclone not found\""; exit 1; }
JQ="$(resolve_bin jq)" || JQ=""

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
clean() { grep -v 'shared Google Drive client_id' | tail -5 | tr '\n' ' ' | tr -d '"' | cut -c1-300; }
emit() { printf '%s\n' "$*"; }

if [ ! -s "$RESTIC_PASSWORD_FILE" ]; then
  emit "ts=$(now_iso) job=restic-l3 status=error reason=\"password file missing\""
  exit 1
fi

# --- loopback で rclone serve restic を立てる ---
port=""
for p in $(seq "$PORT_RANGE_START" $((PORT_RANGE_START + 20))); do
  if ! ss -ltn 2>/dev/null | grep -q ":$p "; then port="$p"; break; fi
done
if [ -z "$port" ]; then
  emit "ts=$(now_iso) job=restic-l3 status=error reason=\"no free loopback port\""
  exit 1
fi

serve_pass="$(openssl rand -hex 16)"
serve_log="$(mktemp -t rclone-serve-XXXXXX.log)"
serve_pid=""
cleanup() {
  [ -n "$serve_pid" ] && kill "$serve_pid" 2>/dev/null
  rm -f "$serve_log"
}
trap cleanup EXIT

"$RCLONE" serve restic \
  --addr "127.0.0.1:$port" \
  --user restic --pass "$serve_pass" \
  --transfers "$REST_CONNECTIONS" \
  "$L3_RCLONE_PATH" > "$serve_log" 2>&1 &
serve_pid=$!

# 🔴 90 秒待つ。30 秒では足りないことが実際にあった (2026-09-02 の timer 発火で
#    `rclone serve failed to listen` になり、rclone は生きているのに 30 秒以内に
#    bind しなかった。手で叩くと 3〜6 秒なので、OAuth トークンの更新か Drive API の
#    遅延と思われる)。失敗時に serve が生きていたかを残しておくと次の診断が速い。
listening=0
for _ in $(seq 1 90); do
  if ss -ltn 2>/dev/null | grep -q ":$port "; then listening=1; break; fi
  kill -0 "$serve_pid" 2>/dev/null || break
  sleep 1
done
if [ "$listening" -ne 1 ]; then
  alive=0; kill -0 "$serve_pid" 2>/dev/null && alive=1
  emit "ts=$(now_iso) job=restic-l3 status=error reason=\"rclone serve failed to listen\" port=$port serve_alive=$alive error=\"$(clean < "$serve_log")\""
  exit 1
fi

L3_REPO="rest:http://restic:$serve_pass@127.0.0.1:$port/"

# --- copy (L1 -> L3) ---
s=$(date +%s)
# 🔴 rc=11 は「リポジトリのロックに失敗」。中断されたジョブが L1/L3 に残した
#    ロックが原因。`restic unlock` は既定で stale なロックしか消さない。
do_copy() {
  "$RESTIC" -r "$L3_REPO" copy \
    -o "rest.connections=$REST_CONNECTIONS" \
    --from-repo "$L1_REPO" \
    --password-file "$RESTIC_PASSWORD_FILE" \
    --from-password-file "$RESTIC_PASSWORD_FILE" 2>&1
}
out="$(do_copy)"
rc=$?
if [ $rc -eq 11 ]; then
  "$RESTIC" -r "$L3_REPO" --password-file "$RESTIC_PASSWORD_FILE" unlock >/dev/null 2>&1
  "$RESTIC" -r "$L1_REPO" --password-file "$RESTIC_PASSWORD_FILE" unlock >/dev/null 2>&1
  out="$(do_copy)"
  rc=$?
fi
dur=$(($(date +%s) - s))

copied=$(printf '%s' "$out" | grep -cE 'snapshot [0-9a-f]+ saved' || true)
skipped=$(printf '%s' "$out" | grep -cE 'has already been copied' || true)

line="ts=$(now_iso) job=restic-l3 status=$([ $rc -eq 0 ] && echo ok || echo error) rc=$rc duration_s=$dur copied=$copied skipped=$skipped"
[ $rc -ne 0 ] && line="$line error=\"$(printf '%s' "$out" | clean)\""
emit "$line"
[ $rc -ne 0 ] && exit $rc

# --- forget (+ 週 1 回だけ prune) ---
# prune は使いかけの pack を詰め直すので、リモートでは download + reupload になる。
# 日次でやると通信量が跳ねるので日曜だけにする。forget 自体は snapshot ファイルを
# 消すだけなので安い。
prune_args=()
if [ "$(date +%u)" = "${L3_PRUNE_DOW:-7}" ]; then prune_args=(--prune); fi

s=$(date +%s)
out="$("$RESTIC" -r "$L3_REPO" forget \
  -o "rest.connections=$REST_CONNECTIONS" \
  --password-file "$RESTIC_PASSWORD_FILE" \
  --tag "$BACKUP_TAG" \
  --keep-daily "$KEEP_DAILY" \
  --keep-weekly "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY" \
  "${prune_args[@]}" 2>&1)"
f_rc=$?
line="ts=$(now_iso) job=restic-l3-forget status=$([ $f_rc -eq 0 ] && echo ok || echo error) rc=$f_rc pruned=${#prune_args[@]} duration_s=$(($(date +%s) - s))"
[ $f_rc -ne 0 ] && line="$line error=\"$(printf '%s' "$out" | clean)\""
emit "$line"

# --- 現況 (Drive の空きとリポジトリサイズを Grafana から追えるようにする) ---
if [ -n "$JQ" ]; then
  about="$("$RCLONE" about "${L3_RCLONE_PATH%%:*}:" --json 2>/dev/null)"
  if [ -n "$about" ]; then
    read -r d_total d_used d_free <<EOF
$(printf '%s' "$about" | "$JQ" -r '[(.total // 0), (.used // 0), (.free // 0)] | @tsv')
EOF
    emit "ts=$(now_iso) job=restic-l3-quota status=ok drive_total_b=$d_total drive_used_b=$d_used drive_free_b=$d_free"
  fi
  st="$("$RESTIC" -r "$L3_REPO" -o "rest.connections=$REST_CONNECTIONS" \
    --password-file "$RESTIC_PASSWORD_FILE" stats --mode raw-data --json 2>/dev/null)"
  if [ -n "$st" ]; then
    emit "ts=$(now_iso) job=restic-l3-stats status=ok repo_size_b=$(printf '%s' "$st" | "$JQ" -r '.total_size')"
  fi
fi

exit "$f_rc"
