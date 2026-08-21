#!/usr/bin/env bash
# domain-monitor / takeover
#
# サブドメイン乗っ取り (dangling CNAME / takeover) の可能性を subzy + nuclei で走査する。
# 旧 dns-dangling-monitor の後継。日次で走る想定。
#
# 旧版との違い:
#   - Discord への POST と notified.txt による重複抑止をやめた。
#     「鳴り続けないこと」は Grafana Alerting の grouping / repeat_interval が担う。
#   - 既知 false positive は握りつぶさず、finding.suppressed=true を付けて送る。
#     記録には残り、アラートだけ鳴らない。
#
# 送るレコード (check.kind):
#   takeover      … 検出 1 件
#   takeover_run  … このランの要約 (走査ツールの有無も含む)
set -euo pipefail

# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

dm_init persistent
START_EPOCH="$(date +%s)"

export PATH="$HOME/go/bin:$PATH"

if ! dm_vantage_ok; then
  dm_otlp_add WARN "外向き通信が確立できないため走査をスキップした" \
    "check.kind=takeover_run" "run.network_ok=false" "run.skipped=true"
  dm_otlp_flush
  exit 0
fi

# ---- 走査対象 = critical に書いたホスト + discover.sh が見つけたホスト ----
TARGETS="$DM_RUN_DIR/targets.txt"
{
  sed 's/#.*//' "$DM_CONFIG_DIR/hosts.critical.txt" | awk 'NF { print $1 }'
  if [ -f "$DM_STATE_DIR/hosts.discovered.txt" ]; then
    cat "$DM_STATE_DIR/hosts.discovered.txt"
  fi
} | tr -d '[:blank:]' | awk 'NF' | sort -u > "$TARGETS"

N_TARGETS="$(wc -l < "$TARGETS")"
dm_log "走査対象: ${N_TARGETS} 件"

if [ "$N_TARGETS" -eq 0 ]; then
  dm_otlp_add WARN "走査対象が 0 件だった" \
    "check.kind=takeover_run" "run.targets=0" "run.skipped=true"
  dm_otlp_flush
  exit 0
fi

# ---- subzy ----
SUBZY_OUT="$DM_RUN_DIR/subzy.json"
SUBZY_AVAILABLE=false
if command -v subzy > /dev/null 2>&1; then
  SUBZY_AVAILABLE=true
  dm_log "subzy 実行中"
  subzy run --targets "$TARGETS" --hide_fails --output "$SUBZY_OUT" --concurrency 10 \
    > "$DM_RUN_DIR/subzy.log" 2>&1 || true
fi

# ---- nuclei (takeover タグのみ) ----
NUCLEI_OUT="$DM_RUN_DIR/nuclei.jsonl"
NUCLEI_AVAILABLE=false
if command -v nuclei > /dev/null 2>&1; then
  NUCLEI_AVAILABLE=true
  dm_log "nuclei 実行中 (-tags takeover)"
  nuclei -list "$TARGETS" -tags takeover -silent -jsonl -o "$NUCLEI_OUT" \
    > "$DM_RUN_DIR/nuclei.log" 2>&1 || true
fi

# ---- 検出を TSV に集約: tool<TAB>host<TAB>signature ----
FINDINGS="$DM_RUN_DIR/findings.tsv"
: > "$FINDINGS"

if [ -s "$SUBZY_OUT" ]; then
  # subzy >= 2.x は status:"vulnerable"、古い版は vulnerable:true。両対応にしておく。
  jq -r '
    (if type == "array" then . else [.] end)
    | .[]
    | select(((.status // "") | ascii_downcase) == "vulnerable" or (.vulnerable // false) == true)
    | "subzy\t\(.subdomain // .target // "?")\t\(.engine // .service // .fingerprint // "?")"
  ' "$SUBZY_OUT" >> "$FINDINGS" || dm_log "subzy の出力を解釈できなかった"
fi

if [ -s "$NUCLEI_OUT" ]; then
  jq -r '"nuclei\t" + (.host // .["matched-at"] // "?") + "\t" + (.["template-id"] // "?")' \
    "$NUCLEI_OUT" >> "$FINDINGS" || dm_log "nuclei の出力を解釈できなかった"
fi

sort -u -o "$FINDINGS" "$FINDINGS"

ALLOW="$DM_CONFIG_DIR/takeover-allow.txt"
touch "$ALLOW"

N_FINDINGS=0
N_SUPPRESSED=0
while IFS=$'\t' read -r tool host sig; do
  [ -z "${tool:-}" ] && continue
  N_FINDINGS=$((N_FINDINGS + 1))

  suppressed=false
  if grep -Fxq "$(printf '%s\t%s\t%s' "$tool" "$host" "$sig")" "$ALLOW"; then
    suppressed=true
    N_SUPPRESSED=$((N_SUPPRESSED + 1))
  fi

  sev=ERROR
  [ "$suppressed" = true ] && sev=INFO

  dm_otlp_add "$sev" \
    "乗っ取り可能性を検出: ${host} (${tool}: ${sig})$([ "$suppressed" = true ] && printf ' [既知 false positive]' || true)" \
    "check.kind=takeover" \
    "monitor.target=$host" "monitor.apex=$(dm_apex_of "$host")" \
    "finding.tool=$tool" "finding.signature=$sig" \
    "finding.suppressed=$suppressed"
done < "$FINDINGS"

# 走査ツールが無い / テンプレートが古いと「検出 0 件」と区別できない。
# ツールの有無自体を報告して、Grafana 側で「走査できていない」を検知できるようにする。
DURATION=$(($(date +%s) - START_EPOCH))
run_sev=INFO
if [ "$SUBZY_AVAILABLE" = false ] || [ "$NUCLEI_AVAILABLE" = false ]; then
  run_sev=WARN
fi

dm_otlp_add "$run_sev" \
  "takeover 走査完了: 対象=${N_TARGETS} 検出=${N_FINDINGS} (うち既知 FP=${N_SUPPRESSED}) (${DURATION}s)" \
  "check.kind=takeover_run" "run.network_ok=true" "run.skipped=false" \
  "run.targets=$N_TARGETS" "run.findings=$N_FINDINGS" "run.suppressed=$N_SUPPRESSED" \
  "run.findings_actionable=$((N_FINDINGS - N_SUPPRESSED))" \
  "tool.subzy_available=$SUBZY_AVAILABLE" \
  "tool.nuclei_available=$NUCLEI_AVAILABLE" \
  "run.duration_s=$DURATION"

dm_otlp_flush
