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
# ここを書き換えるときは SKILL.md の手順 4 も併せて直すこと。
PROMPT="${RESOURCE_AUDIT_PROMPT:-リソース監査レポートを出して。これは週次の自動実行なので、レポートを書き終えたら最後に要約を Discord にも流して。}"
# claude はペインの対話シェルが `agent start --kind claude` で起動する (= そのシェルの PATH で解決される)。
# ここで存在だけ確かめておく。
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

pane_ids() {
  herdr pane list --workspace "$1" 2>/dev/null | jq -r '.result.panes[]?.pane_id' | LC_ALL=C sort || true
}

# herdr 0.9.0 の agent prompt は Enter まで送って確定する
# (0.7.x の「agent send + pane send-keys Enter」の置き換え。agent send は 0.9.0 で消えた)。
# --wait は投入後 5 秒以内に working / blocked が観測できないと agent_prompt_stalled で失敗するので、
# 「本当に走り出したか」の確認を兼ねる。
submit_prompt() {
  local out
  if ! out=$(herdr agent prompt "$AGENT_NAME" "$PROMPT" --wait --until working --until blocked --timeout 30000 2>&1); then
    log "agent prompt に失敗した: $out"
    return 1
  fi
  log "プロンプトを投入した: $(printf '%s' "$out" | jq -c '.result.agent.agent_status // .result // .' 2>/dev/null || printf '%s' "$out")"
}

# ---- 1. 専用ワークスペースを用意する (無ければ作る) -------------------------
WS_CREATED=false
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
  WS_CREATED=true
fi
log "workspace: $WS_ID ($WS_LABEL)"

# ---- 2. 既存エージェントがあれば再利用する ---------------------------------
# agent start で起動したものは name を持つので agent get <name> で引ける。
# 見つかればプロンプトを投げるだけ = ペインを増やさない。
AGENT_JSON=$(herdr agent get "$AGENT_NAME" 2>/dev/null || true)
PANE_ID=$(printf '%s' "$AGENT_JSON" | jq -r '.result.agent.pane_id // empty' 2>/dev/null || true)

if [ -n "$PANE_ID" ]; then
  log "既存エージェントを再利用する (pane=$PANE_ID)"
  if ! submit_prompt; then
    fallback_notify "既存の resource-audit ペインにプロンプトを投入できませんでした。講評なしの数値のみです。"
    exit 1
  fi
  # ここから先は claude が Discord へ要約を流す (SKILL.md の手順 4)。
  exit 0
fi

# ---- 3. 無ければシェルのペインを用意して起動する ---------------------------
# herdr 0.9.0 の agent start は新しいペインを作らず、「シェルのプロンプトにいる既存ペイン」で
# エージェントを起動する (--pane 必須)。0.7.x の --workspace / --cwd / --no-focus は無い。
log "エージェントが居ないので起動する"
if [ "$WS_CREATED" = true ]; then
  # workspace create が作った初期ペイン (シェル) をそのまま使う。
  NEW_PANE=$(pane_ids "$WS_ID" | head -n 1 || true)
else
  # 既存ワークスペースに居るペインは人が使っているかもしれないので乗っ取らない。
  # 専用のタブを足し、増えたペインを使う (tab create の出力形式に依存しないよう差分で取る)。
  BEFORE=$(pane_ids "$WS_ID")
  herdr tab create --workspace "$WS_ID" --cwd "$CWD" --label "$AGENT_NAME" --no-focus >/dev/null 2>&1 || true
  NEW_PANE=$(LC_ALL=C comm -13 <(printf '%s\n' "$BEFORE") <(pane_ids "$WS_ID") | head -n 1 || true)
fi
if [ -z "$NEW_PANE" ]; then
  log "起動先のペインを用意できなかった"
  fallback_notify "resource-audit 用のペインを用意できませんでした。講評なしの数値のみです。"
  exit 1
fi

# シェルが起動しきる前に start すると「プロンプトに居ない」で弾かれうる。
sleep 3
if ! OUT=$(herdr agent start "$AGENT_NAME" --kind claude --pane "$NEW_PANE" --timeout 90000 \
  -- --dangerously-skip-permissions 2>&1); then
  log "agent start に失敗した (pane=$NEW_PANE): $OUT"
  fallback_notify "resource-audit のエージェントを起動できませんでした。講評なしの数値のみです。"
  exit 1
fi
log "起動した (pane=$NEW_PANE)"

if ! submit_prompt; then
  fallback_notify "resource-audit のエージェントは起動したが、プロンプトを投入できませんでした。講評なしの数値のみです。"
  exit 1
fi
# ここから先は claude が Discord へ要約を流す (SKILL.md の手順 4)。
