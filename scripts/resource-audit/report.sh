#!/usr/bin/env bash
# resource-audit reporter (Tier 2 の起動役)
# 専用 herdr ワークスペース内に claude のペインを 1 つだけ維持し、そこへ
# 「リソース監査レポートを出して」というプロンプトを投げる。
# レポートが出たあとユーザーがそのまま会話を続けられるのが狙い。
#
# ⚠ このスクリプトは pane close / workspace close を一切呼ばない。
#    herdr のペインを閉じる操作は隣のペインを巻き込みうるので、掃除は人がやる。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="${SCRIPT_DIR}/notify-discord.sh"

WS_LABEL="${RESOURCE_AUDIT_WS_LABEL:-resource-audit}"
AGENT_NAME="${RESOURCE_AUDIT_AGENT_NAME:-resource-audit}"
CWD="${RESOURCE_AUDIT_CWD:-$HOME/workspace/machine}"
# 「週次の自動実行」の文言がスキルの Discord 送信ステップのトリガーになる。
# ここを書き換えるときは SKILL.md の手順 5 も併せて直すこと。
PROMPT="${RESOURCE_AUDIT_PROMPT:-リソース監査レポートを出して。これは週次の自動実行なので、レポートを書き終えたら最後に要約を Discord にも流して。}"
CLAUDE_BIN="${RESOURCE_AUDIT_CLAUDE_BIN:-$HOME/.local/bin/claude}"

# systemd timer の PATH には ~/.local/bin が入らない。
export PATH="$HOME/.local/bin:$PATH"

log() { printf '[%s] %s\n' "$(date -Is)" "$*" >&2; }

# claude にレポートを書かせられなかったときの保険。
# 週次の結果が「どこにも出ないまま消える」のを防ぐのが目的なので、
# 講評抜きでも数値とアラートだけは Discord に流す。
fallback_notify() {
  [ -x "$NOTIFY" ] || { log "notify-discord.sh が無いのでフォールバック通知もできない"; return 0; }
  "$NOTIFY" --from-snapshot --note "$1" || log "フォールバック通知に失敗した"
}

command -v herdr >/dev/null || { log "herdr が見つからない"; exit 1; }
[ -x "$CLAUDE_BIN" ] || { log "claude が見つからない: $CLAUDE_BIN"; exit 1; }

# herdr server が動いていなければペインを作れない (ログイン前など)。
# 収集自体は ExecStartPre で済んでいるので、数値だけ Discord に流して終わる。
if ! herdr workspace list >/dev/null 2>&1; then
  log "herdr server に接続できないので数値サマリだけ通知する"
  fallback_notify "herdr server に接続できずレポート用のペインを作れませんでした。講評なしの数値のみです。"
  exit 0
fi

ws_id_by_label() {
  herdr workspace list 2>/dev/null \
    | jq -r --arg l "$WS_LABEL" 'first(.result.workspaces[]? | select(.label == $l) | .workspace_id) // empty'
}

# ---- 1. 専用ワークスペースを用意する (無ければ作る) -------------------------
WS_ID=$(ws_id_by_label)
if [ -z "$WS_ID" ]; then
  log "ワークスペース '$WS_LABEL' が無いので作る"
  herdr workspace create --label "$WS_LABEL" --cwd "$CWD" --no-focus >/dev/null 2>&1 || true
  WS_ID=$(ws_id_by_label)
  if [ -z "$WS_ID" ]; then
    log "ワークスペースの作成に失敗した"
    fallback_notify "herdr のワークスペース '${WS_LABEL}' を作れずレポートを書かせられませんでした。講評なしの数値のみです。"
    exit 1
  fi
fi
log "workspace: $WS_ID ($WS_LABEL)"

# ---- 2. 既存エージェントがあれば再利用する ---------------------------------
# agent start で起動したものは name を持つので agent get <name> で引ける。
# 見つかれば pane run でプロンプトを投げるだけ = ペインを増やさない。
AGENT_JSON=$(herdr agent get "$AGENT_NAME" 2>/dev/null || true)
PANE_ID=$(printf '%s' "$AGENT_JSON" | jq -r '.result.agent.pane_id // empty' 2>/dev/null || true)

if [ -n "$PANE_ID" ]; then
  log "既存エージェントを再利用する (pane=$PANE_ID)"
  # ⚠ claude の TUI では pane run / agent send だけだと入力欄に文字が乗るだけで
  #    確定しない (実測: status が working にならない)。Enter を別途送る必要がある。
  if ! herdr agent send "$AGENT_NAME" "$PROMPT" >/dev/null \
    || ! { sleep 1; herdr pane send-keys "$PANE_ID" Enter >/dev/null; }; then
    log "既存ペインへのプロンプト投入に失敗した"
    fallback_notify "既存の resource-audit ペインにプロンプトを投入できませんでした。講評なしの数値のみです。"
    exit 1
  fi
  sleep 3
  STATUS=$(herdr agent get "$AGENT_NAME" 2>/dev/null | jq -r '.result.agent.agent_status // "unknown"' || echo unknown)
  log "プロンプトを投入した (status=$STATUS)"
  # ここから先は claude が Discord へ要約を流す (SKILL.md の手順 5)。
  exit 0
fi

# ---- 3. 無ければ専用ワークスペース内に起動する -----------------------------
log "エージェントが居ないので起動する"
if ! herdr agent start "$AGENT_NAME" \
  --workspace "$WS_ID" \
  --cwd "$CWD" \
  --no-focus \
  -- "$CLAUDE_BIN" --dangerously-skip-permissions "$PROMPT" >/dev/null; then
  log "agent start に失敗した"
  fallback_notify "resource-audit のエージェントを起動できませんでした。講評なしの数値のみです。"
  exit 1
fi

sleep 3
NEW_PANE=$(herdr agent get "$AGENT_NAME" 2>/dev/null | jq -r '.result.agent.pane_id // empty' || true)
if [ -n "$NEW_PANE" ]; then
  log "起動した (pane=$NEW_PANE)"
  # ここから先は claude が Discord へ要約を流す (SKILL.md の手順 5)。
else
  log "起動したが agent get で見つからない (要確認)"
  fallback_notify "エージェントを起動したが herdr から引けませんでした。レポートが書かれたか不明なため数値のみ流します。"
fi
