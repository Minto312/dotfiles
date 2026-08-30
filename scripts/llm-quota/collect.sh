#!/usr/bin/env bash
# llm-quota — コーディングエージェント CLI 3 種の残 quota を測定して OTLP で吐く
#
# ## 責務の境界 (domain-monitor と同じ)
#
# ここは「測定して OTLP で吐く」だけ。閾値判定・flap 抑制・grouping・通知は
# **observability 基盤側 (Grafana Alerting)** の責務。
#
#   llm-quota ──OTLP──> Alloy ──> VictoriaLogs ──> Grafana Alerting ──> Discord
#
# したがって **このファイルに資格情報を書いてはいけない** (dotfiles は public)。
#
# ## 3 種とも「ターンも quota も消費しない」経路がある (実測 2026-08-24)
#
#   agy    : `agy -p='/usage' --output-format json`  → 構造化 JSON。num_turns=0
#   claude : `claude -p "/usage" --output-format json` → num_turns=0 / cost=0 だが
#            **result はテキスト**なので正規表現で読む
#   codex  : `codex app-server` に JSON-RPC で account/rateLimits/read
#            (rollout JSONL の rate_limits は古いスナップショットなので使えない)
#
# 0 コストなので頻度を上げられる。逆に「測ったこと自体で数字が動く」心配も無い。
#
# ## 単位の正規化
#
# 3 者で表現が違う (agy は remaining の小数、claude は used の整数 %、codex は
# usedPercent) ので、**used_ratio / remaining_ratio (0.0-1.0)** に揃えて出す。
# ダッシュボードとアラートを provider 横断で 1 本にできるようにするため。

set -uo pipefail

export LC_ALL=C

LQ_VERSION="1.0.0"
LQ_SERVICE_NAME="${OTEL_SERVICE_NAME:-llm-quota}"
LQ_SCOPE="${LQ_SCOPE:-llm-quota}"
LQ_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${OTEL_EXPORTER_OTLP_LOGS_ENDPOINT:-}" ]; then
  LQ_OTLP_URL="$OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"
else
  LQ_OTLP_URL="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://127.0.0.1:4318}/v1/logs"
fi

LQ_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llm-quota.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -rf -- '$LQ_TMP_DIR'" EXIT
LQ_BUF="$LQ_TMP_DIR/otlp.ndjson"
: > "$LQ_BUF"

lq_log() { printf '[%s] %s\n' "$(date -Is)" "$*" >&2; }

# ---------------------------------------------------------------------------
# lq_add <SEVERITY> <body> [key=value ...]
#
# ⚠ provider / bucket のような値は **log record 側**の属性に付ける。resource 属性に
#   入れると VictoriaLogs の stream が爆発する (observability/docs/instrumentation.md)。
# ---------------------------------------------------------------------------
lq_add() {
  local sev="$1" body="$2"
  shift 2
  local sevnum
  case "$sev" in
    DEBUG) sevnum=5 ;;
    INFO) sevnum=9 ;;
    WARN) sevnum=13 ;;
    ERROR) sevnum=17 ;;
    *) sev=INFO; sevnum=9 ;;
  esac
  local now_ns
  now_ns="$(date +%s%N)"

  # key=value は jq の位置引数として渡す。値に = や空白が入っても壊れない。
  jq -nc \
    --arg sev "$sev" --argjson sevnum "$sevnum" \
    --arg body "$body" --arg ts "$now_ns" '
      $ARGS.positional
      | map(select(index("=") != null))
      | map(
          (index("=")) as $i
          | { key: .[:$i],
              value: (
                .[$i+1:] as $v
                | if   $v == "true"  then { boolValue: true }
                  elif $v == "false" then { boolValue: false }
                  elif ($v | test("^-?[0-9]+$"))          then { intValue: $v }
                  elif ($v | test("^-?[0-9]+\\.[0-9]+$")) then { doubleValue: ($v | tonumber) }
                  else { stringValue: $v }
                  end
              ) }
        )
      | { timeUnixNano: $ts,
          observedTimeUnixNano: $ts,
          severityNumber: $sevnum,
          severityText: $sev,
          body: { stringValue: $body },
          attributes: . }
    ' --args "$@" >> "$LQ_BUF"
}

lq_flush() {
  if [ ! -s "$LQ_BUF" ]; then
    lq_log "送信するレコードが無い"
    return 0
  fi
  local n payload
  n="$(wc -l < "$LQ_BUF")"
  payload="$(jq -sc \
    --arg svc "$LQ_SERVICE_NAME" --arg ver "$LQ_VERSION" --arg scope "$LQ_SCOPE" '{
      resourceLogs: [ {
        resource: { attributes: [
          { key: "service.name",    value: { stringValue: $svc } },
          { key: "service.version", value: { stringValue: $ver } }
        ] },
        scopeLogs: [ { scope: { name: $scope, version: $ver }, logRecords: . } ]
      } ]
    }' "$LQ_BUF")"

  if [ "${LQ_OTLP_DISABLE:-0}" = "1" ]; then
    printf '%s\n' "$payload" | jq .
    lq_log "LQ_OTLP_DISABLE=1 なので送信せず標準出力に出した (${n} 件)"
    return 0
  fi

  local attempt code
  for attempt in 1 2 3; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' -m 20 \
      -X POST "$LQ_OTLP_URL" \
      -H 'Content-Type: application/json' \
      --data-binary "$payload" 2>> "$LQ_TMP_DIR/otlp.err" || echo 000)"
    case "$code" in
      2*) lq_log "OTLP に ${n} 件送信した (HTTP ${code})"; return 0 ;;
      *) lq_log "OTLP 送信に失敗した (HTTP ${code}, attempt ${attempt}/3)"; sleep $((attempt * 2)) ;;
    esac
  done
  lq_log "OTLP 送信を 3 回試して諦めた"
  return 1
}

# 窓の長さ (分) を人が読めるラベルにする。provider 間で揃える。
lq_window_label() {
  case "$1" in
    10080) printf 'weekly' ;;
    300) printf '5h' ;;
    1440) printf 'daily' ;;
    *) printf '%sm' "$1" ;;
  esac
}

# 1 バケット = 1 レコード。used_ratio は必ず小数表記にして doubleValue に落とす
# (整数だと intValue になり、VictoriaLogs 側で型が混ざる)。
# ---------------------------------------------------------------------------
# resets_at の正規化
#
# provider ごとに書式が違う。agy / codex は ISO8601 UTC だが、**claude だけ
# `Aug 30, 12:20am (UTC)` / `Aug 30, 2pm (UTC)` という人間可読形式で、しかも
# 年が入っていない**(分が無い場合もある)。epoch に揃えたうえで 2 つ出す:
#
#   resets_at    = ISO8601 UTC  … 機械可読。アラートやデバッグ用
#   resets_label = JST の表示用 … 5h は HH:MM、weekly は MM-DD HH:MM
#
# パースできなかったときは生値を resets_at に残す (情報を落とさないため)。
# ---------------------------------------------------------------------------
lq_resets_epoch() {
  local raw="$1" cleaned year epoch now
  [ -z "$raw" ] && return 1
  case "$raw" in
    *T*[Zz])
      date -u -d "$raw" +%s 2>/dev/null || return 1
      return 0
      ;;
  esac
  # カンマと括弧を落とすと GNU date が読める ("Aug 30 12:20am UTC")。
  cleaned="$(printf '%s' "$raw" | tr -d ',()')"
  year="$(date -u +%Y)"
  epoch="$(date -u -d "$cleaned $year" +%s 2>/dev/null)" || return 1
  now="$(date -u +%s)"
  # 年が無いので、12 月に測って 1 月の reset を見ると去年と解釈されてしまう。
  # reset は必ず未来なので、過去に落ちたら翌年と読み替える。
  if [ "$epoch" -lt "$((now - 86400))" ]; then
    epoch="$(date -u -d "$cleaned $((year + 1))" +%s 2>/dev/null)" || return 1
  fi
  printf '%s' "$epoch"
}

lq_emit_bucket() {
  local provider="$1" bucket="$2" window="$3" used="$4" resets="$5" plan="$6"
  local used_f remaining_f resets_at resets_label epoch left_s
  used_f="$(printf '%.6f' "$used")"
  remaining_f="$(printf '%.6f' "$(awk -v u="$used" 'BEGIN { printf "%.6f", 1 - u }')")"

  resets_at="$resets"
  resets_label=""
  if epoch="$(lq_resets_epoch "$resets")" && [ -n "$epoch" ]; then
    resets_at="$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$window" = "5h" ]; then
      resets_label="$(TZ=Asia/Tokyo date -d "@$epoch" +%H:%M)"
      # 5h 窓は「あと何時間何分で戻るか」の方が知りたいので併記する。
      # ⚠ これは**測定時点の**残りなので、画面上は最大 1 測定ぶん (5 分) 古い。
      #    Grafana 側では現在時刻を使った計算ができないので、ここで出すしかない。
      left_s=$(( epoch - $(date -u +%s) ))
      if [ "$left_s" -gt 0 ]; then
        resets_label="$resets_label (left $(( left_s / 3600 ))h $(printf '%02d' $(( (left_s % 3600) / 60 )))m)"
      fi
    else
      resets_label="$(TZ=Asia/Tokyo date -d "@$epoch" '+%m-%d %H:%M')"
    fi
  fi

  lq_add INFO \
    "$(printf '%s %s: %.1f%% used (残 %.1f%%)' "$provider" "$bucket" \
      "$(awk -v u="$used" 'BEGIN { printf "%.4f", u * 100 }')" \
      "$(awk -v u="$used" 'BEGIN { printf "%.4f", (1 - u) * 100 }')")" \
    "provider=$provider" \
    "bucket=$bucket" \
    "window=$window" \
    "used_ratio=$used_f" \
    "remaining_ratio=$remaining_f" \
    "resets_at=$resets_at" \
    "resets_label=$resets_label" \
    "plan=$plan" \
    "probe.ok=true"
}

lq_emit_probe_failure() {
  local provider="$1" reason="$2"
  lq_add WARN "$provider の quota を取得できなかった: $reason" \
    "provider=$provider" "probe.ok=false" "error.message=$reason"
}

# ---------------------------------------------------------------------------
# agy (Google Antigravity CLI)
#   `/usage` は read-only slash command なので num_turns=0 / quota 消費 0。
#   ⚠ agy の -p は**値を密着**させる必要がある (-p='/usage')。空白で分けると
#     後続のフラグをプロンプトとして食う。
# ---------------------------------------------------------------------------
probe_agy() {
  local bin out
  bin="$(command -v agy 2>/dev/null)" || true
  if [ -z "$bin" ]; then
    lq_emit_probe_failure agy "agy not found on PATH"
    return 1
  fi
  out="$(timeout 60 "$bin" -p='/usage' --output-format json 2>/dev/null)" || true
  if [ -z "$out" ]; then
    lq_emit_probe_failure agy "empty response"
    return 1
  fi

  local rows
  rows="$(printf '%s' "$out" | jq -r '
    .command.data.groups[]?
    | .name as $group
    | .buckets[]?
    | [ .id, (.window // "unknown"), (1 - .remaining_fraction), (.reset_time // ""), $group ]
    | @tsv
  ' 2>/dev/null)" || true
  if [ -z "$rows" ]; then
    lq_emit_probe_failure agy "could not parse buckets"
    return 1
  fi

  local id window used resets group n=0
  while IFS=$'\t' read -r id window used resets group; do
    [ -n "$id" ] || continue
    lq_emit_bucket agy "$id" "$window" "$used" "$resets" "google-ai-pro"
    n=$((n + 1))
  done <<< "$rows"
  lq_log "agy: ${n} バケット"
  return 0
}

# ---------------------------------------------------------------------------
# claude (Claude Code)
#   `-p "/usage"` は num_turns=0 / total_cost_usd=0 で返る。
#   ⚠ ただし result は**テキスト**なので正規表現で読む。数字は整数 % なので
#     分解能は 1% しかない。
#     例: "Current session: 7% used · resets Aug 24, 5:40pm (UTC)"
#         "Current week (all models): 4% used · resets Aug 30, 2pm (UTC)"
#         "Current week (Fable): 0% used"
# ---------------------------------------------------------------------------
probe_claude() {
  local bin out text
  bin="$(command -v claude 2>/dev/null)" || true
  if [ -z "$bin" ]; then
    lq_emit_probe_failure claude "claude not found on PATH"
    return 1
  fi
  # ⚠ --no-session-persistence が無いと 1 回ごとに ~3.3KB のセッション JSONL が
  #   ~/.claude/projects/ に残る (5 分間隔なら 288 個/日)。print モード限定のフラグ。
  # 🔴 --strict-mcp-config が無いと ~/.claude.json の MCP サーバを全部起動する。
  #   playwright は shared-browser のラッパーなので、測定 1 回ごとにブラウザスロットを
  #   1 つ予約して返さない (2026-08-29 に実測。20 スロットが 5 分間隔なら 100 分で枯渇し、
  #   人間のセッションが `空きスロットが無い` でブラウザを使えなくなる)。
  #   /usage に MCP は要らない。所要も 2.7 秒 → 1.7 秒に縮む (実測 3 回平均)。
  # ⚠ </dev/null が無いと claude は stdin を 3 秒待ってから
  #   `no stdin data received in 3s` を stderr に出して進む。丸ごと無駄なので塞ぐ。
  out="$(timeout 120 "$bin" -p "/usage" --output-format json --no-session-persistence --strict-mcp-config </dev/null 2>/dev/null)" || true
  text="$(printf '%s' "$out" | jq -r '.result // empty' 2>/dev/null)" || true
  if [ -z "$text" ]; then
    lq_emit_probe_failure claude "empty or unparsable response"
    return 1
  fi

  local n=0
  while IFS= read -r line; do
    case "$line" in
      "Current session:"*|"Current week"*) ;;
      *) continue ;;
    esac
    local pct bucket window resets
    pct="$(printf '%s' "$line" | sed -n 's/.*: *\([0-9][0-9]*\)% used.*/\1/p')"
    [ -n "$pct" ] || continue

    if [[ "$line" == "Current session:"* ]]; then
      bucket="session"
      # claude の "Current session" は 5 時間窓 (実測: 13:21 UTC 時点の reset が
      # 17:40 UTC = 4h19m 後)。agy の 5h バケットと同じ window ラベルに揃えておくと
      # 「5h 窓が 95% を超えた」を provider 横断の 1 ルールで書ける。
      window="5h"
    else
      # "Current week (all models)" → week-all-models
      bucket="week-$(printf '%s' "$line" \
        | sed -n 's/^Current week (\([^)]*\)).*/\1/p' \
        | tr '[:upper:] ' '[:lower:]-')"
      window="weekly"
    fi
    resets="$(printf '%s' "$line" | sed -n 's/.*resets \(.*\)$/\1/p')"

    lq_emit_bucket claude "$bucket" "$window" \
      "$(awk -v p="$pct" 'BEGIN { printf "%.6f", p / 100 }')" "$resets" "subscription"
    n=$((n + 1))
  done <<< "$text"

  if [ "$n" -eq 0 ]; then
    lq_emit_probe_failure claude "no usage lines matched"
    return 1
  fi
  lq_log "claude: ${n} バケット"
  return 0
}

# ---------------------------------------------------------------------------
# codex (OpenAI Codex CLI)
#   app-server の account/rateLimits/read。ターンを起こさない。
# ---------------------------------------------------------------------------
probe_codex() {
  local out ok
  out="$(timeout 60 python3 "$LQ_SCRIPT_DIR/codex-rate-limits.py" 2>/dev/null)" || true
  ok="$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" || true
  if [ "$ok" != "true" ]; then
    lq_emit_probe_failure codex "$(printf '%s' "$out" | jq -r '.error // "unknown"' 2>/dev/null)"
    return 1
  fi

  local plan
  plan="$(printf '%s' "$out" | jq -r '.rate_limits.planType // "unknown"')"

  # primary / secondary の両方を同じ形で出す (secondary は null のことがある)。
  local rows
  rows="$(printf '%s' "$out" | jq -r '
    .rate_limits as $r
    | ["primary","secondary"]
    | map(. as $k | $r[$k] | select(. != null) | [$k, .usedPercent, .windowDurationMins, (.resetsAt // 0)])
    | .[] | @tsv
  ' 2>/dev/null)" || true
  if [ -z "$rows" ]; then
    lq_emit_probe_failure codex "no rate limit windows in response"
    return 1
  fi

  local kind pct mins resets n=0
  while IFS=$'\t' read -r kind pct mins resets; do
    [ -n "$kind" ] || continue
    local window resets_iso
    window="$(lq_window_label "$mins")"
    if [ "$resets" -gt 0 ] 2>/dev/null; then
      resets_iso="$(date -u -d "@$resets" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')"
    else
      resets_iso=""
    fi
    lq_emit_bucket codex "codex-$window" "$window" \
      "$(awk -v p="$pct" 'BEGIN { printf "%.6f", p / 100 }')" "$resets_iso" "$plan"
    n=$((n + 1))
  done <<< "$rows"

  # クレジットは 2 種類ある。混同しないように両方別属性で出す。
  #   credits.balance          … 課金クレジットの残高 (usage を買い足したぶん)
  #   reset_credits.available  … 「レートリミットを 1 回だけ全回復させる券」の枚数
  local credits reset_credits
  credits="$(printf '%s' "$out" | jq -r '.rate_limits.credits.balance // "0"')"
  reset_credits="$(printf '%s' "$out" | jq -r '.rate_limits._resetCredits.availableCount // 0')"
  lq_add INFO "codex のクレジット: 課金残高=$credits / リセット券=$reset_credits 枚" \
    "provider=codex" "bucket=credits" \
    "credits.balance=$credits" "reset_credits.available=$reset_credits" \
    "plan=$plan" "probe.ok=true"

  lq_log "codex: ${n} バケット (plan=$plan)"
  return 0
}

# ---------------------------------------------------------------------------
main() {
  local ok=0 total=0 failed=()
  for p in agy claude codex; do
    total=$((total + 1))
    if "probe_$p"; then
      ok=$((ok + 1))
    else
      failed+=("$p")
    fi
  done

  # run サマリ。「1 件も来ていない」と「全部正常」を Grafana 側で区別するために必ず出す。
  local sev=INFO
  [ "$ok" -eq "$total" ] || sev=WARN
  lq_add "$sev" "llm-quota run: ${ok}/${total} providers ok" \
    "run.providers_ok=$ok" \
    "run.providers_total=$total" \
    "run.failed=$(IFS=,; printf '%s' "${failed[*]:-}")"

  lq_flush
}

main "$@"
