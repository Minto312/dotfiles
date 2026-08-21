#!/usr/bin/env bash
# resource-audit の Discord 送信口
#
# 2 つの経路から呼ばれる:
#   1. 週次レポートを書いた Tier 2 の claude が、要約を stdin で渡してくる (主経路)
#   2. report.sh が herdr にペインを作れなかったとき、--from-snapshot で
#      summary.json から機械生成した数値サマリを流す (フォールバック)
#
# webhook は resource-audit 専用の ~/.config/resource-audit/env を使う
# (discord-notify スキルとは別チャンネル。無ければ discord-notify の値に落ちる)。
# 未設定でも呼び出し側を壊さないよう exit 0 で抜ける (collect.sh と同じ方針)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${RESOURCE_AUDIT_STATE:-$HOME/.local/state/resource-audit}"

log() { printf '[%s] notify-discord: %s\n' "$(date -Is)" "$*" >&2; }

# 環境変数が優先。systemd unit は EnvironmentFile で渡してくるが、
# 対話シェルから直に叩く場合はここで読む。
# 専用 env を先に見る。週次レポートの要約は herdr のペインの claude が直に
# このスクリプトを叩くので unit の EnvironmentFile が効かない。ここの順序が実質の宛先。
if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
  for ENV_FILE in \
    "${XDG_CONFIG_HOME:-$HOME/.config}/resource-audit/env" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/discord-notify/env"; do
    # shellcheck source=/dev/null
    [ -f "$ENV_FILE" ] && . "$ENV_FILE" && break
  done
fi
WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"

FROM_SNAPSHOT=0
DRY_RUN=0
NOTE=""
ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --from-snapshot) FROM_SNAPSHOT=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --note) NOTE="${2:-}"; shift ;;
    --help|-h)
      sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

# ---- 本文を組み立てる -------------------------------------------------------
# summary.json から機械生成する。claude の講評は入らないので、数値と
# 現在のアラートだけを並べる (フォールバック用)。
build_from_snapshot() {
  local sum="${STATE_DIR}/latest/summary.json"
  local alerts="${STATE_DIR}/latest/alerts.txt"
  [ -f "$sum" ] || { log "summary.json が無い: $sum"; return 1; }

  local alert_body=""
  [ -s "$alerts" ] && alert_body=$(awk -F'\t' '{print "・" $2}' "$alerts")

  jq -r --arg alerts "$alert_body" --arg note "$NOTE" '
    def gib: (. / 1073741824 * 10 | round) / 10;
    def mib: (. / 1048576 * 10 | round) / 10;
    [
      "**[resource-audit] 週次サマリ — \(.host) / \(.ts[0:4])-\(.ts[4:6])-\(.ts[6:8])**",
      (if $note == "" then empty else $note end),
      "",
      "load \(.cpu.load1)/\(.cpu.load5)/\(.cpu.load15) (\(.cpu.cores) core)  mem \(.mem.anon_bytes|gib)/\(.mem.total_bytes|gib) GiB  disk \(.disk.root_use_pct)%  swap \(.swap.used_bytes|mib) MiB",
      "PSI full(avg300) cpu \(.pressure_full_avg300.cpu) / io \(.pressure_full_avg300.io) / mem \(.pressure_full_avg300.memory)",
      "エージェント \(.agents.total) 本 (idle \(.agents.idle) / working \(.agents.working) / blocked \(.agents.blocked)) 最古 \(.agents.oldest_days) 日",
      "",
      (if $alerts == "" then "現在のアラート: なし。"
       else "現在のアラート \($alerts | split("\n") | length) 件:\n\($alerts)" end),
      "",
      "`/resource-audit` で詳細レポートを出せます。"
    ] | join("\n")
  ' "$sum"
}

if [ "$FROM_SNAPSHOT" = 1 ]; then
  BODY=$(build_from_snapshot)
elif [ "${#ARGS[@]}" -gt 0 ]; then
  BODY="${ARGS[*]}"
else
  BODY=$(cat)
fi

if [ -z "${BODY//[[:space:]]/}" ]; then
  log "本文が空なので送らない"
  exit 0
fi

# content の上限は 2000 "文字" (バイトではない)。
# jq -Rs ならコードポイントで数えて切るので日本語が途中で壊れない。
# --dry-run でも同じものを見せたいので、送信判定より前に組む。
PAYLOAD=$(printf '%s' "$BODY" \
  | jq -Rs 'if length > 2000 then .[:1980] + "\n…(truncated)" else . end | {content: .}')

# 送らずに本文だけ確認する (webhook を持たない検証用)。
if [ "$DRY_RUN" = 1 ]; then
  log "--dry-run: 送信せず、実際に送られる content を出す (元 ${#BODY} 文字)"
  printf '%s\n' "$PAYLOAD" | jq -r '.content'
  exit 0
fi

if [ -z "$WEBHOOK_URL" ]; then
  log "DISCORD_WEBHOOK_URL 未設定のため送信をスキップした"
  exit 0
fi

RESP=$(mktemp)
trap 'rm -f "$RESP"' EXIT

post() {
  curl -sS -o "$RESP" -w '%{http_code}' \
    -H 'Content-Type: application/json' -X POST -d "$PAYLOAD" "$WEBHOOK_URL"
}

CODE=$(post || echo 000)

# レート制限は 1 度だけ待って再送する (discord-notify スキルと同じ方針)。
if [ "$CODE" = 429 ]; then
  WAIT=$(jq -r '.retry_after // 2' "$RESP" 2>/dev/null || echo 2)
  log "429 を受けたので ${WAIT}s 待って 1 度だけ再送する"
  sleep "$WAIT"
  CODE=$(post || echo 000)
fi

case "$CODE" in
  200|204) log "送信した (HTTP $CODE, ${#BODY} 文字)" ;;
  *) log "送信に失敗した (HTTP $CODE): $(head -c 300 "$RESP" 2>/dev/null)"; exit 1 ;;
esac
