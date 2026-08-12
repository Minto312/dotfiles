#!/usr/bin/env bash
# resource-audit reporter (Tier 2 の起動役)
# 専用 herdr ワークスペース内に claude のペインを 1 つだけ維持し、そこへ
# 「リソース監査レポートを出して」というプロンプトを投げる。
# レポートが出たあとユーザーがそのまま会話を続けられるのが狙い。
#
# ⚠ このスクリプトは pane close / workspace close を一切呼ばない。
#    herdr のペインを閉じる操作は隣のペインを巻き込みうるので、掃除は人がやる。
set -euo pipefail

WS_LABEL="${RESOURCE_AUDIT_WS_LABEL:-resource-audit}"
AGENT_NAME="${RESOURCE_AUDIT_AGENT_NAME:-resource-audit}"
CWD="${RESOURCE_AUDIT_CWD:-$HOME/workspace/machine}"
PROMPT="${RESOURCE_AUDIT_PROMPT:-リソース監査レポートを出して}"
CLAUDE_BIN="${RESOURCE_AUDIT_CLAUDE_BIN:-$HOME/.local/bin/claude}"

# systemd timer の PATH には ~/.local/bin が入らない。
export PATH="$HOME/.local/bin:$PATH"

log() { printf '[%s] %s\n' "$(date -Is)" "$*" >&2; }

command -v herdr >/dev/null || { log "herdr が見つからない"; exit 1; }
[ -x "$CLAUDE_BIN" ] || { log "claude が見つからない: $CLAUDE_BIN"; exit 1; }

# herdr server が動いていなければ何もしない (ログイン前など)。
if ! herdr workspace list >/dev/null 2>&1; then
  log "herdr server に接続できないのでスキップした"
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
  [ -n "$WS_ID" ] || { log "ワークスペースの作成に失敗した"; exit 1; }
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
  herdr agent send "$AGENT_NAME" "$PROMPT" >/dev/null
  sleep 1
  herdr pane send-keys "$PANE_ID" Enter >/dev/null
  sleep 3
  STATUS=$(herdr agent get "$AGENT_NAME" 2>/dev/null | jq -r '.result.agent.agent_status // "unknown"' || echo unknown)
  log "プロンプトを投入した (status=$STATUS)"
  exit 0
fi

# ---- 3. 無ければ専用ワークスペース内に起動する -----------------------------
log "エージェントが居ないので起動する"
herdr agent start "$AGENT_NAME" \
  --workspace "$WS_ID" \
  --cwd "$CWD" \
  --no-focus \
  -- "$CLAUDE_BIN" --dangerously-skip-permissions "$PROMPT" >/dev/null

sleep 3
NEW_PANE=$(herdr agent get "$AGENT_NAME" 2>/dev/null | jq -r '.result.agent.pane_id // empty' || true)
if [ -n "$NEW_PANE" ]; then
  log "起動した (pane=$NEW_PANE)"
else
  log "起動したが agent get で見つからない (要確認)"
fi
