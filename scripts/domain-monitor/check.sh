#!/usr/bin/env bash
# domain-monitor / check
#
# 到達性 (DNS + HTTP) / TLS 期限 / DNS レコードの変化を測定して OTLP で送る。
# 5 分ごとに走る想定。**判定と通知はしない** (Grafana Alerting の責務。lib.sh の冒頭参照)。
#
# 送るレコードの種類 (log record 属性 check.kind):
#   endpoint  … ホスト 1 件の DNS/HTTP/TLS の状態
#   zone      … apex 1 件の NS / MX / SPF / DMARC の状態
#   dns_drift … レコード集合がベースラインから変化した
#   run       … このランの要約 (ハートビート兼用)
set -euo pipefail

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

dm_init ephemeral
START_EPOCH="$(date +%s)"

# ---------------------------------------------------------------------------
# 0. vantage point の健全性
#
# develop 側の回線が落ちているだけで「全ホスト down」と報告してしまうのを防ぐ。
# この場合 endpoint レコードを 1 件も出さない = 誤ったアラートが立たない。
# 代わりに run レコードで network_ok=false を報告するので、
# 「監視できていない」状態そのものは Grafana から見える。
# ---------------------------------------------------------------------------
if ! dm_vantage_ok; then
  dm_otlp_add WARN "外向き通信が確立できないため測定をスキップした (develop 側の回線障害の可能性)" \
    "check.kind=run" "run.network_ok=false" "run.skipped=true" "run.targets=0"
  dm_otlp_flush
  dm_log "vantage point NG: 測定をスキップした"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. 監視対象の組み立て
# ---------------------------------------------------------------------------
declare -A HOST_KIND=()
declare -A HOST_CRIT=()

while IFS= read -r line; do
  line="${line%%#*}"
  host="$(printf '%s\n' "$line" | awk '{print $1}')"
  [ -z "$host" ] && continue
  kind="$(printf '%s\n' "$line" | awk '{print ($2 == "" ? "web" : $2)}')"
  HOST_KIND["$host"]="$kind"
  HOST_CRIT["$host"]=true
done < "$DM_CONFIG_DIR/hosts.critical.txt"

DISCOVERED_FILE="$DM_STATE_DIR/hosts.discovered.txt"
if [ -f "$DISCOVERED_FILE" ]; then
  while IFS= read -r host; do
    host="${host%%#*}"
    host="$(printf '%s' "$host" | tr -d '[:blank:]')"
    [ -z "$host" ] && continue
    [ -n "${HOST_KIND[$host]:-}" ] && continue
    HOST_KIND["$host"]=web
    HOST_CRIT["$host"]=false
  done < "$DISCOVERED_FILE"
fi

dm_log "対象ホスト: ${#HOST_KIND[@]} 件"

# レコード集合を "TYPE<TAB>value" の 1 行 1 レコードで書き出す
emit_rr() {
  local t="$1" csv="$2"
  [ -z "$csv" ] && return 0
  printf '%s\n' "$csv" | tr ',' '\n' | awk -v t="$t" 'NF { print t "\t" $0 }'
  return 0
}

# drift を判定して、変化していれば dns_drift レコードを送る
report_drift() {
  local label="$1" cls="$2" alertable="$3" target="$4" apex="$5" cur="$6"
  local verdict sev
  # ⚠ コマンド置換で受けない (サブシェルになり DM_DRIFT_ADDED/_REMOVED が失われる)
  dm_drift "$label" "$cur"
  verdict="$DM_DRIFT_VERDICT"
  case "$verdict" in
    created)
      dm_otlp_add INFO "DNS ベースラインを作成した: ${label} (${cls})" \
        "check.kind=dns_drift" "monitor.target=$target" "monitor.apex=$apex" \
        "dns.class=$cls" "dns.drift=created" "dns.drift.alertable=false"
      ;;
    changed)
      sev=INFO
      [ "$alertable" = true ] && sev=WARN
      dm_otlp_add "$sev" \
        "DNS レコードが変化した: ${label} (${cls}) 追加=[${DM_DRIFT_ADDED}] 削除=[${DM_DRIFT_REMOVED}]" \
        "check.kind=dns_drift" "monitor.target=$target" "monitor.apex=$apex" \
        "dns.class=$cls" "dns.drift=changed" "dns.drift.alertable=$alertable" \
        "dns.drift.added=$DM_DRIFT_ADDED" "dns.drift.removed=$DM_DRIFT_REMOVED"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# 2. ホストごとの測定
# ---------------------------------------------------------------------------
N_OK=0
N_FAIL=0
N_SKIP=0

for host in $(printf '%s\n' "${!HOST_KIND[@]}" | sort); do
  kind="${HOST_KIND[$host]}"
  crit="${HOST_CRIT[$host]}"
  apex="$(dm_apex_of "$host")"
  [ -z "$apex" ] && apex="unknown"

  IFS=$'\t' read -r a_rcode a_vals <<< "$(dm_dig "$host" A)"
  IFS=$'\t' read -r aaaa_rcode aaaa_vals <<< "$(dm_dig "$host" AAAA)"
  IFS=$'\t' read -r cname_rcode cname_vals <<< "$(dm_dig "$host" CNAME)"

  resolvable=false
  if [ -n "$a_vals" ] || [ -n "$aaaa_vals" ] || [ -n "$cname_vals" ]; then
    resolvable=true
  fi

  # ---- HTTP ----
  http_code=""
  http_ms=""
  http_redirect=""
  ssl_verify=""
  remote_ip=""
  curl_rc=0
  curl_err=""
  if [ "$resolvable" = true ] && [ "$kind" = "web" ]; then
    : > "$DM_RUN_DIR/curl.err"
    curl_out="$(curl -sS -o /dev/null -m 15 --connect-timeout 8 \
      -A "domain-monitor/$DM_VERSION (+develop)" \
      -w '%{http_code}|%{time_total}|%{redirect_url}|%{ssl_verify_result}|%{remote_ip}' \
      "https://$host/" 2>> "$DM_RUN_DIR/curl.err")" || curl_rc=$?
    if [ -n "$curl_out" ]; then
      IFS='|' read -r http_code http_time http_redirect ssl_verify remote_ip <<< "$curl_out"
      http_ms="$(awk -v t="${http_time:-0}" 'BEGIN { printf "%d", t * 1000 }')"
    fi
    curl_err="$(tr '\n' ' ' < "$DM_RUN_DIR/curl.err" | cut -c1-200)"
  fi

  # ---- TLS 期限 ----
  # 証明書の妥当性は curl の ssl_verify_result で判る。ここでは期限だけを取る。
  # ⚠ 期限切れ間近の証明書でも中身を読みたいので -verify_return_error は付けない。
  tls_days=""
  tls_not_after=""
  tls_issuer=""
  tls_status="n/a"
  if [ "$resolvable" = true ] && [ "$kind" = "web" ]; then
    cert="$(timeout 15 openssl s_client -servername "$host" -connect "$host:443" \
      < /dev/null 2>/dev/null | openssl x509 -noout -enddate -issuer 2>/dev/null || true)"
    tls_not_after="$(printf '%s\n' "$cert" | sed -n 's/^notAfter=//p' | head -1)"
    tls_issuer="$(printf '%s\n' "$cert" | sed -n 's/^issuer=//p' | head -1)"
    if [ -n "$tls_not_after" ]; then
      exp_epoch="$(date -d "$tls_not_after" +%s 2>/dev/null || true)"
      if [ -n "$exp_epoch" ]; then
        tls_days=$(((exp_epoch - START_EPOCH) / 86400))
        if [ "$tls_days" -lt 0 ]; then
          tls_status=expired
        elif [ "$tls_days" -le 14 ]; then
          tls_status=expiring
        else
          tls_status=ok
        fi
      fi
    else
      # openssl 側だけ失敗することがある。誤アラートを避けるため error ではなく unknown。
      tls_status=unknown
    fi
  fi

  # ---- 判定 ----
  status=ok
  reason=""
  if [ "$kind" = "dns-only" ]; then
    # A/AAAA/CNAME を持たないのが正常なドメイン (メール専用など)。
    # ゾーンが消えたことは check.kind=zone の NS 不在で拾うので、ここでは常に ok。
    status=ok
  elif [ "$resolvable" != true ]; then
    # NOERROR なのに応答が無いのは NODATA (名前は存在するがそのレコード型が無い)。
    # rcode をそのまま使うと "dns_noerror" という紛らわしいラベルになるので分ける。
    if [ "$a_rcode" = "NOERROR" ]; then
      reason="dns_nodata"
    else
      reason="dns_$(printf '%s' "$a_rcode" | tr '[:upper:]' '[:lower:]')"
    fi
    if [ "$crit" = true ]; then status=fail; else status=skip; fi
  elif [ "$curl_rc" -ne 0 ]; then
    status=fail
    reason="curl_exit_${curl_rc}"
  else
    case "$http_code" in
      2?? | 3??) status=ok ;;
      *)
        status=fail
        reason="http_${http_code}"
        ;;
    esac
  fi

  sev=INFO
  [ "$status" = fail ] && sev=ERROR
  if [ "$sev" = INFO ]; then
    case "$tls_status" in
      expiring | expired) sev=WARN ;;
    esac
  fi

  attrs=(
    "check.kind=endpoint"
    "check.status=$status"
    "monitor.target=$host"
    "monitor.apex=$apex"
    "monitor.critical=$crit"
    "monitor.kind=$kind"
    "dns.rcode=$a_rcode"
    "dns.resolvable=$resolvable"
    "tls.status=$tls_status"
  )
  add_attr() {
    if [ -n "$2" ]; then attrs+=("$1=$2"); fi
    return 0
  }
  add_attr "dns.cname" "$cname_vals"
  add_attr "dns.a" "$a_vals"
  add_attr "dns.aaaa" "$aaaa_vals"
  add_attr "fail.reason" "$reason"
  add_attr "http.status_code" "$http_code"
  add_attr "http.duration_ms" "$http_ms"
  add_attr "http.redirect_url" "$http_redirect"
  add_attr "http.remote_ip" "$remote_ip"
  add_attr "tls.verify_result" "$ssl_verify"
  add_attr "tls.days_left" "$tls_days"
  add_attr "tls.not_after" "$tls_not_after"
  add_attr "tls.issuer" "$tls_issuer"
  add_attr "error.message" "$curl_err"

  body="$host: ${status}"
  [ -n "$http_code" ] && body="$body http=${http_code}"
  [ -n "$tls_days" ] && body="$body tls=${tls_days}d"
  [ -n "$reason" ] && body="$body reason=${reason}"

  dm_otlp_add "$sev" "$body" "${attrs[@]}"

  case "$status" in
    ok) N_OK=$((N_OK + 1)) ;;
    fail) N_FAIL=$((N_FAIL + 1)) ;;
    skip) N_SKIP=$((N_SKIP + 1)) ;;
  esac

  # ---- レコード変化 ----
  # stable クラス (CNAME) は変化がそのまま異常のサインなので alertable。
  # address クラス (A/AAAA) は Cloudflare / CloudFront が返す IP が入れ替わるので
  # alertable=false にして記録だけ残す (誤アラートの温床になる)。
  emit_rr CNAME "$cname_vals" | sort > "$DM_RUN_DIR/stable.rr"
  report_drift "$host.stable" stable true "$host" "$apex" "$DM_RUN_DIR/stable.rr"

  {
    emit_rr A "$a_vals"
    emit_rr AAAA "$aaaa_vals"
  } | sort > "$DM_RUN_DIR/address.rr"
  report_drift "$host.address" address false "$host" "$apex" "$DM_RUN_DIR/address.rr"

  dm_log "$body"
done

# ---------------------------------------------------------------------------
# 3. apex (ゾーン) ごとの測定
#
# NS / MX / SPF / DMARC の変化は DNS 乗っ取り・メール偽装の直接のサインなので、
# A レコードと違って必ず alertable にする。
# ---------------------------------------------------------------------------
while IFS= read -r apex; do
  [ -z "$apex" ] && continue

  IFS=$'\t' read -r ns_rcode ns_vals <<< "$(dm_dig "$apex" NS)"
  IFS=$'\t' read -r mx_rcode mx_vals <<< "$(dm_dig "$apex" MX)"
  IFS=$'\t' read -r txt_rcode txt_vals <<< "$(dm_dig "$apex" TXT)"
  IFS=$'\t' read -r dmarc_rcode dmarc_vals <<< "$(dm_dig "_dmarc.$apex" TXT)"

  spf_present=false
  case "$txt_vals" in *"v=spf1"*) spf_present=true ;; esac
  dmarc_present=false
  case "$dmarc_vals" in *"v=DMARC1"*) dmarc_present=true ;; esac

  zsev=INFO
  [ -z "$ns_vals" ] && zsev=ERROR

  dm_otlp_add "$zsev" \
    "$apex zone: ns=$(printf '%s' "$ns_vals" | tr ',' ' ' | wc -w) spf=${spf_present} dmarc=${dmarc_present}" \
    "check.kind=zone" "monitor.target=$apex" "monitor.apex=$apex" \
    "dns.ns=$ns_vals" "dns.mx=$mx_vals" \
    "dns.spf_present=$spf_present" "dns.dmarc_present=$dmarc_present" \
    "dns.rcode=$ns_rcode"

  {
    emit_rr NS "$ns_vals"
    emit_rr MX "$mx_vals"
    emit_rr TXT "$txt_vals"
    emit_rr DMARC "$dmarc_vals"
  } | sort > "$DM_RUN_DIR/zone.rr"
  report_drift "$apex.zone" zone true "$apex" "$apex" "$DM_RUN_DIR/zone.rr"

  dm_log "$apex zone: ns=[${ns_vals}] spf=${spf_present} dmarc=${dmarc_present}"
done < <(dm_apexes)

# ---------------------------------------------------------------------------
# 4. ランの要約 (ハートビート兼用)
#
# このレコードが途切れたことを Grafana 側で検知させる = 監視自体の死活監視。
# ---------------------------------------------------------------------------
DURATION=$(($(date +%s) - START_EPOCH))
dm_otlp_add INFO \
  "check 完了: ok=${N_OK} fail=${N_FAIL} skip=${N_SKIP} (${DURATION}s)" \
  "check.kind=run" "run.network_ok=true" "run.skipped=false" \
  "run.targets=$((N_OK + N_FAIL + N_SKIP))" \
  "run.ok=$N_OK" "run.fail=$N_FAIL" "run.skip=$N_SKIP" \
  "run.duration_s=$DURATION"

dm_otlp_flush
