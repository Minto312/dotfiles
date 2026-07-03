#!/usr/bin/env bash
# DNS dangling monitor
# 監視対象 apex の配下を passive 列挙し、subzy + nuclei takeover で乗っ取り可能性をチェックする。
# 検出があった場合のみ Discord webhook で通知する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAINS_FILE="${DNS_DANGLING_DOMAINS:-${SCRIPT_DIR}/domains.txt}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dns-dangling-monitor"
TS=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="${STATE_DIR}/runs/${TS}"
LATEST_LINK="${STATE_DIR}/latest"
PREV_LINK="${STATE_DIR}/previous"
NOTIFIED_FILE="${STATE_DIR}/notified.txt"

# webhook URL は環境変数経由で渡す (~/.config/dns-dangling-monitor/env で設定)。
WEBHOOK_URL="${DNS_DANGLING_WEBHOOK:-}"

mkdir -p "$RUN_DIR" "$(dirname "$NOTIFIED_FILE")"
touch "$NOTIFIED_FILE"

export PATH="$HOME/go/bin:/opt/go/bin:$PATH"

log() { printf '[%s] %s\n' "$(date -Is)" "$*" >&2; }

# ---- 1. apex を passive 列挙 -------------------------------------------------
SUBS_RAW="${RUN_DIR}/subdomains.raw.txt"
: > "$SUBS_RAW"

while IFS= read -r raw; do
  apex="${raw%%#*}"
  apex="$(printf '%s' "$apex" | tr -d '[:space:]')"
  [ -z "$apex" ] && continue

  log "enumerating: $apex"
  echo "$apex" >> "$SUBS_RAW"

  if command -v subfinder >/dev/null; then
    subfinder -silent -all -d "$apex" 2>>"${RUN_DIR}/subfinder.err" >> "$SUBS_RAW" || true
  fi

  # crt.sh は混雑時 502 を返すので失敗は無視する
  curl -fsSL --max-time 60 "https://crt.sh/?q=%25.${apex}&output=json" \
       2>>"${RUN_DIR}/crtsh.err" \
    | jq -r '.[].name_value' 2>/dev/null \
    | tr '[:upper:]' '[:lower:]' \
    | tr -d '*' \
    | sed 's/^\.//' \
    | tr ',' '\n' \
    | awk 'NF' >> "$SUBS_RAW" || true
done < "$DOMAINS_FILE"

# 監視対象 apex に属する FQDN のみ残して重複排除
SUBS_FILE="${RUN_DIR}/subdomains.txt"
awk_filter=$(awk 'BEGIN{ORS="|"} {gsub(/[#].*/,""); gsub(/[[:space:]]/,""); if (length($0)) print "\\." $0 "$|^" $0 "$"}' "$DOMAINS_FILE" | sed 's/|$//')
if [ -z "$awk_filter" ]; then
  log "no apex domains configured; exiting"
  exit 0
fi
sort -u "$SUBS_RAW" | grep -Ei "$awk_filter" > "$SUBS_FILE" || true
log "candidate subdomains: $(wc -l < "$SUBS_FILE")"

# ---- 2. resolvable (CNAME/A を返す) ものに絞る -------------------------------
ALIVE_FILE="${RUN_DIR}/resolvable.txt"
: > "$ALIVE_FILE"
while IFS= read -r host; do
  [ -z "$host" ] && continue
  if [ -n "$(dig +short +time=3 +tries=1 CNAME "$host" 2>/dev/null | head -1)" ] \
     || [ -n "$(dig +short +time=3 +tries=1 A "$host" 2>/dev/null | head -1)" ]; then
    echo "$host" >> "$ALIVE_FILE"
  fi
done < "$SUBS_FILE"
log "resolvable subdomains: $(wc -l < "$ALIVE_FILE")"

# ---- 3. subzy ----------------------------------------------------------------
SUBZY_OUT="${RUN_DIR}/subzy.json"
if command -v subzy >/dev/null && [ -s "$ALIVE_FILE" ]; then
  log "running subzy"
  subzy run --targets "$ALIVE_FILE" --hide_fails --output "$SUBZY_OUT" --concurrency 10 \
    > "${RUN_DIR}/subzy.log" 2>&1 || true
fi

# ---- 4. nuclei (takeover タグのみ) -------------------------------------------
NUCLEI_OUT="${RUN_DIR}/nuclei.jsonl"
if command -v nuclei >/dev/null && [ -s "$ALIVE_FILE" ]; then
  log "running nuclei (takeovers)"
  nuclei -list "$ALIVE_FILE" -tags takeover -silent -jsonl -o "$NUCLEI_OUT" \
    > "${RUN_DIR}/nuclei.log" 2>&1 || true
fi

# ---- 5. 検出を集計 ------------------------------------------------------------
FINDINGS_FILE="${RUN_DIR}/findings.txt"
: > "$FINDINGS_FILE"

if [ -s "$SUBZY_OUT" ]; then
  # subzy >= 2.x は `status:"vulnerable"` 文字列で表す。古い版は vulnerable:true なので両対応。
  jq -r '
    (if type=="array" then . else [.] end)
    | .[]
    | select(((.status // "") | ascii_downcase) == "vulnerable" or (.vulnerable // false) == true)
    | "subzy\t\(.subdomain // .target // "?")\t\(.engine // .service // .fingerprint // "?")"
  ' "$SUBZY_OUT" >> "$FINDINGS_FILE" || log "subzy parse failed"
fi

if [ -s "$NUCLEI_OUT" ]; then
  jq -r '"nuclei\t" + (.host // .["matched-at"] // "?") + "\t" + (.["template-id"] // "?")' \
    "$NUCLEI_OUT" >> "$FINDINGS_FILE" || log "nuclei parse failed"
fi

# ---- 6. latest / previous の張り替え -----------------------------------------
if [ -L "$LATEST_LINK" ]; then
  PREV_TARGET=$(readlink "$LATEST_LINK")
  ln -sfn "$PREV_TARGET" "$PREV_LINK" 2>/dev/null || true
fi
ln -sfn "$RUN_DIR" "$LATEST_LINK"

# ---- 7. 通知 (新規検出のみ) --------------------------------------------------
NEW_FINDINGS="${RUN_DIR}/findings.new.txt"
if [ -s "$FINDINGS_FILE" ]; then
  # 同じ (tool, host, signature) は 1 度だけ通知 (notified.txt に追記)
  sort -u "$FINDINGS_FILE" > "${FINDINGS_FILE}.sorted"
  comm -23 "${FINDINGS_FILE}.sorted" <(sort -u "$NOTIFIED_FILE") > "$NEW_FINDINGS" || true
else
  : > "$NEW_FINDINGS"
fi

if [ -s "$NEW_FINDINGS" ]; then
  COUNT=$(wc -l < "$NEW_FINDINGS")
  HEAD=$(head -20 "$NEW_FINDINGS" | awk -F'\t' '{printf "- [%s] %s -> %s\n", $1, $2, $3}')
  TAIL=""
  if [ "$COUNT" -gt 20 ]; then
    TAIL=$(printf '\n...(残 %d 件は %s 参照)' $((COUNT-20)) "$RUN_DIR/findings.txt")
  fi
  MSG=$(printf '🚨 **DNS dangling 新規検出** (host: develop)\n件数: %d\n%s%s' "$COUNT" "$HEAD" "$TAIL")
  log "new findings: $COUNT"

  if [ -n "$WEBHOOK_URL" ]; then
    jq -nc --arg content "$MSG" '{content: $content}' \
      | curl -sS --max-time 30 -H 'Content-Type: application/json' \
          -X POST -d @- "$WEBHOOK_URL" >/dev/null \
      && cat "$NEW_FINDINGS" >> "$NOTIFIED_FILE" \
      || log "discord notify failed"
  else
    log "no webhook configured; skipping discord"
  fi
  printf '%s\n' "$MSG"
else
  log "no new findings"
fi

exit 0
