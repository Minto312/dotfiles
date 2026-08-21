#!/usr/bin/env bash
# domain-monitor 共通ライブラリ
#
# ## 責務の境界 (重要)
#
# このスクリプト群は「測定して OTLP で吐く」ことだけを行う。
# 閾値判定・flap 抑制・grouping・通知は **observability 基盤側 (Grafana Alerting)** の責務。
#
#   domain-monitor ──OTLP──> Alloy ──> VictoriaLogs ──> Grafana Alerting ──> Discord
#
# この分割の理由:
#   - dotfiles は PUBLIC リポジトリなので、webhook URL 等をここに置きたくない
#   - 「N 回連続で失敗したら通知」「復旧したら通知」「同種をまとめる」「一時的に黙らせる」は
#     Grafana Alerting が既に持っている。bash に状態機械を再実装すると必ず腐る
#   - 通知先を変えるときに監視スクリプトを触らなくて済む
#
# したがって **このファイル群に資格情報を書いてはいけない**。
#
# shellcheck shell=bash

# ⚠ sort と comm を必ず同じ照合順で動かすため、バイト順に固定する。
#   既定ロケールだと sort はハイフンを無視して並べる (csa-poc < csa < csa-staging) のに
#   comm はそれを「ソートされていない」と判断し、差分が壊れる。実際に踏んだ。
export LC_ALL=C

DM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DM_CONFIG_DIR="${DM_CONFIG_DIR:-$DM_SCRIPT_DIR}"
DM_STATE_DIR="${DM_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/domain-monitor}"
DM_VERSION="1.0.0"
DM_SERVICE_NAME="${OTEL_SERVICE_NAME:-domain-monitor}"
DM_SCOPE="${DM_SCOPE:-domain-monitor}"

# OTLP の送り先。observability の契約 (docs/instrumentation.md) に従う:
#   OTEL_EXPORTER_OTLP_LOGS_ENDPOINT があればパスまで含めてそのまま使う。
#   無ければ OTEL_EXPORTER_OTLP_ENDPOINT に /v1/logs を足す。
if [ -n "${OTEL_EXPORTER_OTLP_LOGS_ENDPOINT:-}" ]; then
  DM_OTLP_URL="$OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"
else
  DM_OTLP_URL="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://127.0.0.1:4318}/v1/logs"
fi

DM_OTLP_BUF=""
DM_RUN_DIR=""
DM_TMP_DIR=""

# ---------------------------------------------------------------------------
# ログ (人間向け)。stdout/stderr は systemd 経由で journald に入り、
# Alloy の journald 経路でも収集される = OTLP が死んでも観測が完全には切れない。
# ---------------------------------------------------------------------------
dm_log() { printf '[%s] %s\n' "$(date -Is)" "$*" >&2; }
dm_die() { dm_log "FATAL: $*"; exit 1; }

# ---------------------------------------------------------------------------
# dm_init <mode>
#   ephemeral  … 実行ごとの作業ディレクトリを mktemp で作り、終了時に消す
#                (check は 5 分ごとに走るので run ディレクトリを残すと inode が溢れる)
#   persistent … $DM_STATE_DIR/runs/<UTC> に成果物を残す (audit 用)
# ---------------------------------------------------------------------------
dm_init() {
  local mode="${1:-ephemeral}"
  mkdir -p "$DM_STATE_DIR/dns"

  case "$mode" in
    persistent)
      DM_RUN_DIR="$DM_STATE_DIR/runs/$(date -u +%Y%m%dT%H%M%SZ)"
      mkdir -p "$DM_RUN_DIR"
      ln -sfn "$DM_RUN_DIR" "$DM_STATE_DIR/latest"
      # 古いランを間引く (30 世代)。ディスクを食い潰した前例があるので必ずやる。
      # shellcheck disable=SC2012
      ls -1d "$DM_STATE_DIR"/runs/*/ 2>/dev/null | sort | head -n -30 |
        while IFS= read -r old; do rm -rf -- "$old"; done
      ;;
    *)
      DM_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/domain-monitor.XXXXXX")"
      DM_RUN_DIR="$DM_TMP_DIR"
      # shellcheck disable=SC2064
      trap "rm -rf -- '$DM_TMP_DIR'" EXIT
      ;;
  esac

  DM_OTLP_BUF="$DM_RUN_DIR/otlp.ndjson"
  : > "$DM_OTLP_BUF"
}

# ---------------------------------------------------------------------------
# dm_otlp_add <SEVERITY> <body> [key=value ...]
#
# ⚠ 高カーディナリティな値 (対象ホスト名など) は **log record の属性**に付ける。
#   resource 属性に入れると VictoriaLogs の stream が爆発する
#   (observability/docs/instrumentation.md)。この関数は必ず log record 側に付ける。
# ---------------------------------------------------------------------------
dm_otlp_add() {
  local sev="$1" body="$2"
  shift 2
  local sevnum
  case "$sev" in
    DEBUG) sevnum=5 ;;
    INFO) sevnum=9 ;;
    WARN) sevnum=13 ;;
    ERROR) sevnum=17 ;;
    *)
      sev=INFO
      sevnum=9
      ;;
  esac
  local now_ns
  now_ns="$(date +%s%N)"

  # key=value は jq の **位置引数** ($ARGS.positional) として渡す。
  # 区切り文字を挟まないので、値に = / 空白 / 改行 / 引用符が入っても壊れない。
  # (NUL 区切りで標準入力から渡す手は使えない: jq は文字列中の NUL を扱えない)
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
    ' --args "$@" >> "$DM_OTLP_BUF"
}

# ---------------------------------------------------------------------------
# dm_otlp_flush
#
# resource 属性は service.name / service.version だけ送る。
# host.name / deployment.environment.name は Alloy が埋める (契約どおり)。
# ---------------------------------------------------------------------------
dm_otlp_flush() {
  if [ ! -s "$DM_OTLP_BUF" ]; then
    dm_log "送信するレコードが無い"
    return 0
  fi
  local n payload
  n="$(wc -l < "$DM_OTLP_BUF")"
  payload="$(jq -sc \
    --arg svc "$DM_SERVICE_NAME" --arg ver "$DM_VERSION" --arg scope "$DM_SCOPE" '{
      resourceLogs: [ {
        resource: { attributes: [
          { key: "service.name",    value: { stringValue: $svc } },
          { key: "service.version", value: { stringValue: $ver } }
        ] },
        scopeLogs: [ { scope: { name: $scope, version: $ver }, logRecords: . } ]
      } ]
    }' "$DM_OTLP_BUF")"

  if [ "${DM_OTLP_DISABLE:-0}" = "1" ]; then
    printf '%s\n' "$payload"
    dm_log "DM_OTLP_DISABLE=1 なので送信せず標準出力に出した (${n} 件)"
    return 0
  fi

  local attempt code
  for attempt in 1 2 3; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' -m 20 \
      -X POST "$DM_OTLP_URL" \
      -H 'Content-Type: application/json' \
      --data-binary "$payload" 2>> "$DM_RUN_DIR/otlp.err" || echo 000)"
    case "$code" in
      200 | 202)
        dm_log "OTLP 送信 ok: ${n} 件 (HTTP $code)"
        return 0
        ;;
    esac
    dm_log "OTLP 送信 失敗: HTTP $code (attempt ${attempt}/3)"
    [ "$attempt" -lt 3 ] && sleep $((attempt * 3))
  done

  # 送れなかった payload は落として原因追跡できるようにする。
  mkdir -p "$DM_STATE_DIR/failed"
  printf '%s\n' "$payload" > "$DM_STATE_DIR/failed/$(date -u +%Y%m%dT%H%M%SZ).json"
  dm_log "OTLP 送信を諦めた。payload を $DM_STATE_DIR/failed/ に保存した"
  return 1
}

# ---------------------------------------------------------------------------
# dm_dig <host> <type>  ->  "<RCODE><TAB><value1,value2,...>"
#
# dig を 1 回だけ叩いて rcode と ANSWER SECTION の両方を取る。
# CNAME を経由するホストへの A クエリは CNAME + A が返るので、type で絞る。
# ---------------------------------------------------------------------------
dm_dig() {
  local host="$1" type="$2" out status answers
  out="$(dig +time=3 +tries=2 "$type" "$host" 2>/dev/null || true)"
  status="$(printf '%s\n' "$out" |
    sed -n 's/^;; ->>HEADER<<-.*status: \([A-Z]*\).*/\1/p' | head -1)"
  [ -z "$status" ] && status="TIMEOUT"
  answers="$(printf '%s\n' "$out" | awk -v t="$type" '
      /^;; ANSWER SECTION:/ { inans = 1; next }
      inans && /^$/         { inans = 0 }
      inans && $4 == t      { $1 = $2 = $3 = $4 = ""; sub(/^ +/, ""); print }
    ' | sort -u | paste -sd, -)"
  printf '%s\t%s\n' "$status" "$answers"
}

# ---------------------------------------------------------------------------
# dm_drift <label> <current-sorted-file>
#
# 結果は **グローバル変数**に入れる: DM_DRIFT_VERDICT (created|same|changed) と、
# changed のときの DM_DRIFT_ADDED / DM_DRIFT_REMOVED。
#
# ⚠ 値を stdout に echo して `v=$(dm_drift ...)` で受けてはいけない。
#   コマンド置換はサブシェルなので ADDED/REMOVED の代入が親に伝わらず、
#   差分が常に空になる (実際にこのバグを踏んだ: 2026-08-20)。
# 判定後は必ずベースラインを現在値で置き換える (同じ変化を延々と報告しないため。
# 「まだ直っていない」の再通知は Grafana の repeat_interval が受け持つ)。
# ---------------------------------------------------------------------------
DM_DRIFT_VERDICT=""
DM_DRIFT_ADDED=""
DM_DRIFT_REMOVED=""
dm_drift() {
  local label="$1" cur="$2"
  local base="$DM_STATE_DIR/dns/${label}.baseline"
  DM_DRIFT_VERDICT=""
  DM_DRIFT_ADDED=""
  DM_DRIFT_REMOVED=""

  if [ ! -f "$base" ]; then
    sort -u "$cur" > "$base"
    DM_DRIFT_VERDICT=created
    return 0
  fi

  # comm に渡す前に両方を必ず並べ直す。古いバージョンが別の照合順で書いた
  # ベースラインが残っていても差分が壊れないようにするため。
  local nb nc
  nb="$(mktemp "${TMPDIR:-/tmp}/dm-base.XXXXXX")"
  nc="$(mktemp "${TMPDIR:-/tmp}/dm-cur.XXXXXX")"
  sort -u "$base" > "$nb"
  sort -u "$cur" > "$nc"

  if cmp -s "$nb" "$nc"; then
    rm -f -- "$nb" "$nc"
    DM_DRIFT_VERDICT=same
    return 0
  fi
  DM_DRIFT_ADDED="$(comm -13 "$nb" "$nc" | paste -sd';' -)"
  DM_DRIFT_REMOVED="$(comm -23 "$nb" "$nc" | paste -sd';' -)"
  cp "$nc" "$base"
  rm -f -- "$nb" "$nc"
  DM_DRIFT_VERDICT=changed
}

# ---------------------------------------------------------------------------
# 監視対象 apex の一覧 (domains.txt)
# ---------------------------------------------------------------------------
dm_apexes() {
  sed 's/#.*//' "$DM_CONFIG_DIR/domains.txt" | tr -d '[:blank:]' | awk 'NF'
}

# dm_apex_of <host> -> domains.txt の中で最も長く後方一致する apex
dm_apex_of() {
  local host="$1" apex best=""
  while IFS= read -r apex; do
    case "$host" in
      "$apex" | *".$apex")
        if [ "${#apex}" -gt "${#best}" ]; then best="$apex"; fi
        ;;
    esac
  done < <(dm_apexes)
  printf '%s\n' "$best"
}

# ---------------------------------------------------------------------------
# dm_vantage_ok
#
# このマシン自身の外向き通信が生きているかを先に確かめる。
# develop の回線が落ちているだけで「全ホスト down」と報告するのを防ぐ
# (単一 vantage point での監視の最大の弱点)。
# 監視対象と無関係な先を 3 つ見て、1 つでも通れば OK とする。
# ---------------------------------------------------------------------------
dm_vantage_ok() {
  dig +short +time=2 +tries=1 @1.1.1.1 cloudflare.com A > /dev/null 2>&1 && return 0
  dig +short +time=2 +tries=1 @8.8.8.8 google.com A > /dev/null 2>&1 && return 0
  curl -sS -o /dev/null -m 8 https://www.google.com/generate_204 > /dev/null 2>&1 && return 0
  return 1
}
