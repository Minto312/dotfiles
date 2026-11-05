#!/usr/bin/env bash
# restic のリポジトリを Google Drive に置くための部品。source して使う。
#
#   start_rclone_serve <rclone のパス (例: gdrive:restic/develop-user)> <ジョブ名>
#     成功すると REST_REPO (restic に渡す URL) と REPO_OPTS (restic の -o) を設定して 0 を返す。
#     失敗すると logfmt の error 行を 1 行出して 1 を返す。
#   stop_rclone_serve   … trap EXIT から呼ぶ
#
# 呼ぶ側で RCLONE (rclone の実行ファイル) と now_iso を用意しておくこと。
# root から呼ぶときは RCLONE_RUN_AS=karinto を渡す。rclone の設定と OAuth トークンは
# karinto の ~/.config/rclone にあり、root で rclone を動かすとトークン更新時に
# 設定ファイルが root の持ち物に書き換わってしまうため、serve だけ karinto で動かす。
#
# 🔴 restic の rclone バックエンド (`rclone:` URL) は使わない。
#    それは内部で `rclone serve restic --stdio` を起動し、全リクエストが
#    1 本のパイプ上で直列化されるため、実測で 110 KiB/s しか出ない。
#    loopback の HTTP で serve して REST バックエンドから叩くと 5.1 MiB/s (46 倍)。
#
# 🔴 scope=drive.file は「その OAuth クライアント自身が作ったファイル」しか見えない。
#    client_id を差し替えると旧 client が作った repo は見えなくなるので、
#    client_id を変えるときは repo を作り直すこと (旧パスは手で消す)。
# 🔴 rclone の共有 client_id は 2026 年中に廃止される。
#    専用 client_id への移行が必要 (machine/storage/backup-develop.md §4.6)。

: "${REST_CONNECTIONS:=8}"
# 18080 は別の (正体不明の loopback) サービスが使っていたので既定から外している
: "${PORT_RANGE_START:=18091}"
: "${RCLONE_RUN_AS:=}"

RCLONE_SERVE_PID=""
RCLONE_SERVE_LOG=""
REST_REPO=""
REPO_OPTS=()

# serve が先に死んでいても kill の失敗で止まらないようにする
# (set -e の下では `a && kill` の kill 失敗で trap ごと抜け、ログが残る)
stop_rclone_serve() {
  if [ -n "$RCLONE_SERVE_PID" ]; then kill "$RCLONE_SERVE_PID" 2>/dev/null || true; fi
  if [ -n "$RCLONE_SERVE_LOG" ]; then rm -f "$RCLONE_SERVE_LOG"; fi
  RCLONE_SERVE_PID=""
}

_rclone_serve_clean() { grep -v 'shared Google Drive client_id' | tail -5 | tr '\n' ' ' | tr -d '"' | cut -c1-300; }

start_rclone_serve() {
  local path="$1" job="$2" port="" p pass
  for p in $(seq "$PORT_RANGE_START" $((PORT_RANGE_START + 20))); do
    if ! ss -ltn 2>/dev/null | grep -q ":$p "; then port="$p"; break; fi
  done
  if [ -z "$port" ]; then
    printf 'ts=%s job=%s status=error reason="no free loopback port"\n' "$(now_iso)" "$job"
    return 1
  fi

  pass="$(openssl rand -hex 16)"
  RCLONE_SERVE_LOG="$(mktemp -t rclone-serve-XXXXXX.log)"
  local prefix=()
  if [ -n "$RCLONE_RUN_AS" ] && [ "$(id -un)" != "$RCLONE_RUN_AS" ]; then
    local home; home="$(getent passwd "$RCLONE_RUN_AS" | cut -d: -f6)"
    # 🔴 ログを $RCLONE_RUN_AS へ chown しないこと。ログは root のシェルが開いて
    #    rclone に渡すので所有者を変える必要はなく、変えると /tmp (sticky) の
    #    fs.protected_regular=2 により root でも開けず rclone が起動しない (2026-11-05)。
    prefix=(runuser -u "$RCLONE_RUN_AS" -- env HOME="$home")
  fi
  "${prefix[@]}" "$RCLONE" serve restic \
    --addr "127.0.0.1:$port" \
    --user restic --pass "$pass" \
    --transfers "$REST_CONNECTIONS" \
    "$path" > "$RCLONE_SERVE_LOG" 2>&1 &
  RCLONE_SERVE_PID=$!

  # 🔴 90 秒待つ。30 秒では足りないことが実際にあった (2026-09-02 の timer 発火で
  #    `rclone serve failed to listen` になり、rclone は生きているのに 30 秒以内に
  #    bind しなかった。手で叩くと 3〜6 秒なので、OAuth トークンの更新か Drive API の
  #    遅延と思われる)。失敗時に serve が生きていたかを残しておくと次の診断が速い。
  local listening=0
  for _ in $(seq 1 90); do
    if ss -ltn 2>/dev/null | grep -q ":$port "; then listening=1; break; fi
    kill -0 "$RCLONE_SERVE_PID" 2>/dev/null || break
    sleep 1
  done
  if [ "$listening" -ne 1 ]; then
    local alive=0; kill -0 "$RCLONE_SERVE_PID" 2>/dev/null && alive=1
    printf 'ts=%s job=%s status=error reason="rclone serve failed to listen" port=%s serve_alive=%s error="%s"\n' \
      "$(now_iso)" "$job" "$port" "$alive" "$(_rclone_serve_clean < "$RCLONE_SERVE_LOG")"
    return 1
  fi

  REST_REPO="rest:http://restic:$pass@127.0.0.1:$port/"
  REPO_OPTS=(-o "rest.connections=$REST_CONNECTIONS")
  return 0
}
