#!/usr/bin/env bash
# domain-monitor / discover
#
# apex 配下のサブドメインを passive 列挙し、解決できるものを
# $DM_STATE_DIR/hosts.discovered.txt に書き出す (check.sh が best-effort 対象として読む)。
#
# 新しいサブドメインが生えたこと自体が情報なので (想定外の公開・証明書発行の兆候)、
# 前回との差分を OTLP で報告する。日次で走る想定。
#
# 送るレコード (check.kind):
#   discovery      … 新規 / 消失したホスト 1 件
#   discovery_run  … このランの要約
set -euo pipefail

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

dm_init persistent
START_EPOCH="$(date +%s)"

if ! dm_vantage_ok; then
  dm_otlp_add WARN "外向き通信が確立できないため列挙をスキップした" \
    "check.kind=discovery_run" "run.network_ok=false" "run.skipped=true"
  dm_otlp_flush
  exit 0
fi

SUBS_RAW="$DM_RUN_DIR/subdomains.raw.txt"
: > "$SUBS_RAW"

N_APEX=0
while IFS= read -r apex; do
  [ -z "$apex" ] && continue
  N_APEX=$((N_APEX + 1))
  dm_log "列挙中: $apex"
  printf '%s\n' "$apex" >> "$SUBS_RAW"

  if command -v subfinder > /dev/null 2>&1; then
    subfinder -silent -all -d "$apex" 2>> "$DM_RUN_DIR/subfinder.err" >> "$SUBS_RAW" || true
  else
    dm_otlp_add WARN "subfinder が見つからないため passive 列挙を省略した" \
      "check.kind=discovery_run" "tool.name=subfinder" "tool.available=false"
  fi

  # crt.sh は混雑時に 502 を返す。subfinder 側で概ね拾えるので失敗は無視する。
  curl -fsSL --max-time 60 "https://crt.sh/?q=%25.${apex}&output=json" \
    2>> "$DM_RUN_DIR/crtsh.err" |
    jq -r '.[].name_value' 2> /dev/null |
    tr '[:upper:]' '[:lower:]' |
    tr -d '*' |
    sed 's/^\.//' |
    tr ',' '\n' |
    awk 'NF' >> "$SUBS_RAW" || true
done < <(dm_apexes)

# ---- 監視対象 apex に属する妥当な FQDN だけ残す ----
FILTER_RE="$(dm_apexes | sed 's/\./\\./g' | awk '{ printf "(^|\\.)%s$|", $0 }' | sed 's/|$//')"
if [ -z "$FILTER_RE" ]; then
  dm_die "domains.txt に apex が 1 件も無い"
fi

# passive source (subfinder / crt.sh) は同じホストを毎日返すとは限らない。
# 前回列挙できたホストを候補に混ぜておかないと、列挙が揺れただけで
# 「消えた → 生えた」が出る (dev.relay で 9 日に 2 回発生。DNS は生きたままだった)。
# 本当に DNS から消えたものは下の解決チェックで落ちるので gone の検知は保たれる。
# apex を domains.txt から外したホストは FILTER_RE で除かれるので残り続けない。
KNOWN="$DM_STATE_DIR/hosts.discovered.txt"
touch "$KNOWN"

CAND="$DM_RUN_DIR/candidates.txt"
sort -u "$SUBS_RAW" "$KNOWN" |
  grep -E '^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$' |
  grep -Ei "$FILTER_RE" > "$CAND" || true
dm_log "候補: $(wc -l < "$CAND") 件 (passive 列挙 + 前回既知 $(wc -l < "$KNOWN") 件)"

# ---- 解決できるものだけ残す ----
ALIVE="$DM_RUN_DIR/discovered.txt"
: > "$ALIVE"
while IFS= read -r h; do
  [ -z "$h" ] && continue
  vals=""
  for t in A CNAME AAAA; do
    IFS=$'\t' read -r _rc vals <<< "$(dm_dig "$h" "$t")"
    [ -n "$vals" ] && break
  done
  if [ -n "$vals" ]; then printf '%s\n' "$h" >> "$ALIVE"; fi
done < "$CAND"
sort -u -o "$ALIVE" "$ALIVE"
dm_log "解決できたホスト: $(wc -l < "$ALIVE") 件"

# ---- 前回との差分 ----
PREV="$DM_STATE_DIR/hosts.discovered.txt"
BASELINE_CREATED=false
if [ ! -s "$PREV" ]; then BASELINE_CREATED=true; fi
touch "$PREV"

NEW_LIST="$DM_RUN_DIR/new.txt"
GONE_LIST="$DM_RUN_DIR/gone.txt"
# 両側を必ず同じ照合順 (LC_ALL=C。lib.sh で固定) で並べ直してから comm に渡す。
comm -13 <(sort -u "$PREV") <(sort -u "$ALIVE") > "$NEW_LIST" || true
comm -23 <(sort -u "$PREV") <(sort -u "$ALIVE") > "$GONE_LIST" || true

cp "$ALIVE" "$PREV"

# domains.txt に apex を足した直後は、その配下のホストが全部「新規」に見える。
# 実際には「新しく監視対象になった」だけで、生えたわけではない。
# apex ごとに「一度でも列挙したか」を持って、初回列挙の apex 配下は報告から外す。
SEEN_APEXES="$DM_STATE_DIR/apexes.seen"
touch "$SEEN_APEXES"
FIRST_APEXES="$DM_RUN_DIR/first-seen-apexes.txt"
comm -13 <(sort -u "$SEEN_APEXES") <(dm_apexes | sort -u) > "$FIRST_APEXES" || true
N_FIRST_APEX="$(wc -l < "$FIRST_APEXES")"
N_SUPPRESSED=0

if [ -s "$FIRST_APEXES" ]; then
  KEEP="$DM_RUN_DIR/new.reportable.txt"
  : > "$KEEP"
  while IFS= read -r h; do
    [ -z "$h" ] && continue
    if grep -Fxq "$(dm_apex_of "$h")" "$FIRST_APEXES"; then
      N_SUPPRESSED=$((N_SUPPRESSED + 1))
    else
      printf '%s\n' "$h" >> "$KEEP"
    fi
  done < "$NEW_LIST"
  mv "$KEEP" "$NEW_LIST"
  dm_log "初回列挙の apex ($(paste -sd, - < "$FIRST_APEXES")) 配下 ${N_SUPPRESSED} 件は新規報告から外した"
fi
dm_apexes | sort -u > "$SEEN_APEXES"

N_NEW="$(wc -l < "$NEW_LIST")"
N_GONE="$(wc -l < "$GONE_LIST")"

# 初回はベースライン作成なので 1 件ずつは報告しない (全件が「新規」になってしまう)。
if [ "$BASELINE_CREATED" = false ]; then
  while IFS= read -r h; do
    [ -z "$h" ] && continue
    dm_otlp_add WARN "新しいサブドメインを検出した: $h" \
      "check.kind=discovery" "discovery.event=new" \
      "monitor.target=$h" "monitor.apex=$(dm_apex_of "$h")"
  done < "$NEW_LIST"

  while IFS= read -r h; do
    [ -z "$h" ] && continue
    dm_otlp_add INFO "サブドメインが解決しなくなった: $h" \
      "check.kind=discovery" "discovery.event=gone" \
      "monitor.target=$h" "monitor.apex=$(dm_apex_of "$h")"
  done < "$GONE_LIST"
fi

DURATION=$(($(date +%s) - START_EPOCH))
dm_otlp_add INFO \
  "discover 完了: apex=${N_APEX} 解決=$(wc -l < "$ALIVE") 新規=${N_NEW} 消失=${N_GONE} 初回列挙apex=${N_FIRST_APEX}(配下${N_SUPPRESSED}件を報告から除外) (${DURATION}s)" \
  "check.kind=discovery_run" "run.network_ok=true" "run.skipped=false" \
  "run.apexes=$N_APEX" "run.candidates=$(wc -l < "$CAND")" \
  "run.resolvable=$(wc -l < "$ALIVE")" \
  "run.new=$N_NEW" "run.gone=$N_GONE" \
  "run.first_seen_apexes=$N_FIRST_APEX" \
  "run.new_suppressed=$N_SUPPRESSED" \
  "run.baseline_created=$BASELINE_CREATED" \
  "run.duration_s=$DURATION"

dm_otlp_flush
