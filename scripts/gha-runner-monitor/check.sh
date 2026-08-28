#!/usr/bin/env bash
# gha-runner-monitor / check
#
# Proxmox 上の Talos クラスタで動く GitHub Actions self-hosted runner (ARC) の
# 死活を測定して OTLP で送る。**判定と通知はしない** (Grafana Alerting の責務)。
#
#   gha-runner-monitor ──OTLP──> Alloy ──> VictoriaLogs ──> Grafana Alerting ──> Discord
#
# なぜ死活監視が要るか:
#   GitHub には self-hosted runner が使えないときの自動フォールバックが無い。
#   listener が死ぬとジョブは失敗せず **キューに残り続ける** (24〜48 時間で cancel)。
#   つまり「CI が赤くならないまま止まる」ので、外形監視でしか気付けない。
#   復旧は relay の repository variable RUNNER_LABEL を消すだけで GitHub-hosted に戻る。
#
# 送るレコードの種類 (log record 属性 check.kind):
#   node      … Talos ノードの Ready 状態
#   component … ARC の構成要素 (controller / listener) 1 件の状態
#   run       … このランの要約 (ハートビート兼用)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="gha-runner-monitor"
VERSION="1"
SCOPE="check"
NAMESPACE_SYS="arc-systems"
NAMESPACE_RUN="arc-runners"

# kubeconfig は dotfiles に置かない (秘密のため)。既定は Talos クラスタのもの。
export KUBECONFIG="${GHA_RUNNER_KUBECONFIG:-$HOME/.talos/gha-runner/kubeconfig}"
# systemd の PATH には ~/.local/bin が無いので kubectl を実体で探す
KUBECTL="${GHA_RUNNER_KUBECTL:-$HOME/.local/bin/kubectl}"
[ -x "$KUBECTL" ] || KUBECTL="$(command -v kubectl || true)"

# OTLP の送り先。observability の契約に従う。
if [ -n "${OTEL_EXPORTER_OTLP_LOGS_ENDPOINT:-}" ]; then
  OTLP_URL="$OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"
else
  OTLP_URL="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://127.0.0.1:4318}/v1/logs"
fi

BUF="$(mktemp)"
trap 'rm -f "$BUF"' EXIT

log() { printf '%s %s\n' "$(date -Is)" "$*" >&2; }

# OTLP の logRecord を 1 件積む。属性は key=value で可変長に渡す。
otlp_add() {
  local sev="$1" body="$2"; shift 2
  local now_ns attrs
  now_ns="$(date +%s)000000000"
  attrs="$(for kv in "$@"; do
    printf '%s\n' "${kv%%=*}"; printf '%s\n' "${kv#*=}"
  done | jq -Rn '[inputs as $k | input as $v | {key: $k, value: {stringValue: $v}}]')"
  jq -cn --arg t "$now_ns" --arg sev "$sev" --arg body "$body" --argjson attrs "$attrs" \
    '{timeUnixNano: $t, severityText: $sev, body: {stringValue: $body}, attributes: $attrs}' >> "$BUF"
}

otlp_flush() {
  [ -s "$BUF" ] || { log "送信するレコードが無い"; return 0; }
  local n payload
  n="$(wc -l < "$BUF")"
  payload="$(jq -sc --arg svc "$SERVICE_NAME" --arg ver "$VERSION" --arg scope "$SCOPE" '{
      resourceLogs: [ {
        resource: { attributes: [
          { key: "service.name",    value: { stringValue: $svc } },
          { key: "service.version", value: { stringValue: $ver } }
        ] },
        scopeLogs: [ { scope: { name: $scope, version: $ver }, logRecords: . } ]
      } ]
    }' "$BUF")"
  if [ "${GHA_RUNNER_OTLP_DISABLE:-0}" = "1" ]; then
    printf '%s\n' "$payload"; log "OTLP 送信を抑止した (${n} 件)"; return 0
  fi
  if curl -fsS -m 10 -X POST -H 'Content-Type: application/json' -d "$payload" "$OTLP_URL" >/dev/null 2>&1; then
    log "OTLP 送信 ${n} 件"
  else
    log "OTLP 送信に失敗した (${OTLP_URL})"
  fi
}

# ---------------------------------------------------------------------------
# 0. kubectl / kubeconfig が使えるか
#
# ここで落ちると「クラスタが死んでいる」のか「監視側が壊れている」のか
# 区別できないので、run レコードで観測不能を明示する。
# ---------------------------------------------------------------------------
if [ -z "$KUBECTL" ] || [ ! -r "$KUBECONFIG" ]; then
  otlp_add ERROR "kubectl または kubeconfig が無く測定できない" \
    "check.kind=run" "run.observable=false" "run.reason=no_kubectl_or_kubeconfig"
  otlp_flush; log "kubectl/kubeconfig が無い"; exit 0
fi

if ! "$KUBECTL" --request-timeout=15s get --raw /readyz >/dev/null 2>&1; then
  otlp_add ERROR "Kubernetes API に到達できない (クラスタ停止 or ネットワーク障害)" \
    "check.kind=run" "run.observable=false" "run.reason=api_unreachable"
  otlp_flush; log "API 到達不可"; exit 0
fi

# ---------------------------------------------------------------------------
# 1. ノードの Ready
# ---------------------------------------------------------------------------
node_total=0; node_ready=0
while IFS=$'\t' read -r name ready; do
  [ -z "$name" ] && continue
  node_total=$((node_total + 1))
  if [ "$ready" = "True" ]; then
    node_ready=$((node_ready + 1)); sev=INFO
  else
    sev=ERROR
  fi
  otlp_add "$sev" "node ${name} ready=${ready}" \
    "check.kind=node" "node.name=$name" "node.ready=$([ "$ready" = "True" ] && echo true || echo false)"
done < <("$KUBECTL" --request-timeout=15s get nodes -o json 2>/dev/null \
  | jq -r '.items[] | [.metadata.name, ([.status.conditions[] | select(.type=="Ready") | .status] | first // "Unknown")] | @tsv')

# ---------------------------------------------------------------------------
# 2. ARC の構成要素
#
# controller が 1 つ、listener が scale set ごとに 1 つ。listener が居ないと
# ジョブが割り当てられず、キューに滞留する (= CI が静かに止まる)。
# ---------------------------------------------------------------------------
comp_total=0; comp_ready=0
while IFS=$'\t' read -r name phase ready; do
  [ -z "$name" ] && continue
  comp_total=$((comp_total + 1))
  case "$name" in
    *-listener) kind=listener ;;
    *) kind=controller ;;
  esac
  if [ "$phase" = "Running" ] && [ "$ready" = "true" ]; then
    comp_ready=$((comp_ready + 1)); sev=INFO; ok=true
  else
    sev=ERROR; ok=false
  fi
  otlp_add "$sev" "${kind} ${name} phase=${phase} ready=${ready}" \
    "check.kind=component" "component.kind=$kind" "component.name=$name" \
    "component.phase=$phase" "component.ready=$ok"
done < <("$KUBECTL" --request-timeout=15s get pods -n "$NAMESPACE_SYS" -o json 2>/dev/null \
  | jq -r '.items[] | [.metadata.name, .status.phase,
      ([.status.conditions[]? | select(.type=="Ready") | .status] | first // "Unknown" | ascii_downcase == "true" | tostring)] | @tsv')

# ---------------------------------------------------------------------------
# 3. 参考値: 現在動いている runner Pod の数
#
# ephemeral なのでジョブが無ければ 0 が正常。アラートには使わないが、
# 「キューは積まれているのに Pod が 0 のまま」を人が見て気付くために送る。
# ---------------------------------------------------------------------------
runner_pods="$("$KUBECTL" --request-timeout=15s get pods -n "$NAMESPACE_RUN" \
  --no-headers 2>/dev/null | grep -vc listener || true)"
runner_pods="${runner_pods:-0}"

otlp_add INFO "ARC の死活を測定した" \
  "check.kind=run" "run.observable=true" \
  "run.nodes_total=$node_total" "run.nodes_ready=$node_ready" \
  "run.components_total=$comp_total" "run.components_ready=$comp_ready" \
  "run.runner_pods=$runner_pods"

otlp_flush
log "完了: node ${node_ready}/${node_total}, component ${comp_ready}/${comp_total}, runner pod ${runner_pods}"
