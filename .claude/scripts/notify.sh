#!/usr/bin/env bash
# Claude Code hook handler.
# Usage: notify.sh <event> <  <hook JSON on stdin>
#
# Events: prompt (UserPromptSubmit) | stop (Stop) | notify (Notification)
#
# 役割:
# 1. OSC 777 (notify) エスケープを /dev/tty に出力 → wezterm が Windows 通知に変換
# 2. 長かったターンの終了時に Stop をブロックし、Claude に PushNotification ツールを
#    呼ばせる → Remote Control 経由でスマホに push が飛ぶ
#
# なぜ 2 を hook 自身で送らないか: モバイル push は HTTP API ではなく Remote Control
# のトランスポート経由で送られる (PushNotificationTool は pushSent を返すだけ)。
# hook から叩ける push エンドポイントは存在しないので、「トリガは hook が決め、
# 送信はモデルにやらせる」という形にしている。
#
# 「blocked」の push は Claude Code 本体が自動で出す (settings.json の
# inputNeededNotifEnabled)。ここで面倒を見るのは「done」側だけ。
#
# (以前は zellij タブ名も書き換えていたが、hook 発火時の active タブが claude の
#  タブとは限らず、無関係なタブをリネームしてしまうため撤去した)

set -uo pipefail

event="${1:-}"
input=$(cat 2>/dev/null || true)

# ターン開始時刻の置き場。cost-summary.json と同じ ~/.claude/cache/ 配下。
STATE_DIR="$HOME/.claude/cache/notify"
# この秒数以上かかったターンだけスマホに push する (毎ターン鳴らすと地獄になる)
MIN_SEC="${CLAUDE_NOTIFY_PUSH_MIN_SEC:-60}"

# OSC 777: rxvt-style notification escape (wezterm が OS 通知に変換)
# /dev/tty に書く必要あり (Claude が hook の stdout/stderr を捕捉する場合があるため)
osc_notify() {
  local title="$1" body="$2"
  # 2>/dev/null を先に置く: /dev/tty が無い環境 (制御 TTY 無しで起動された hook) では
  # リダイレクト自体が失敗し、その診断が hook の stderr に漏れるため
  printf '\e]777;notify;%s;%s\e\\' "$title" "$body" 2>/dev/null >/dev/tty || true
}

# 改行除去 + N 文字に切り詰め
trunc() { printf '%s' "$1" | tr '\n' ' ' | cut -c "1-${2:-30}"; }

# hook JSON から 1 フィールド取る (無ければ空文字)
jqr() { jq -r "${1} // \"\"" <<<"$input" 2>/dev/null || true; }

# session_id をファイル名に使える形に
sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }

case "$event" in
  prompt)
    sid=$(jqr '.session_id')
    [[ -n "$sid" ]] || exit 0
    mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
    printf '%s %s\n' "$(date +%s)" "$(jqr '.prompt_id')" \
      >"$STATE_DIR/$(sanitize "$sid").start" 2>/dev/null || true
    # 放置された state を掃除
    find "$STATE_DIR" -type f -mtime +2 -delete 2>/dev/null || true
    exit 0
    ;;

  stop)
    # transcript_path から「親ディレクトリ名」を抜いてプロジェクト名に
    tp=$(jqr '.transcript_path')
    project=""
    if [[ -n "$tp" ]]; then
      project=$(basename "$(dirname "$tp")")
    fi
    osc_notify "Claude Code" "${project:-task} 完了"

    # ---- ここから「done をスマホに飛ばす」判定 ----

    # 既に一度ブロックして継続中なら二度と割り込まない (無限ループ防止)
    [[ "$(jqr '.stop_hook_active')" == "true" ]] && exit 0
    # サブエージェント由来の停止では何もしない
    [[ -n "$(jqr '.agent_id')" ]] && exit 0

    sid=$(jqr '.session_id')
    [[ -n "$sid" ]] || exit 0
    key=$(sanitize "$sid")
    start_file="$STATE_DIR/$key.start"
    [[ -r "$start_file" ]] || exit 0

    started=""; prompt_id=""
    read -r started prompt_id <"$start_file" || true
    [[ "$started" =~ ^[0-9]+$ ]] || exit 0
    elapsed=$(( $(date +%s) - started ))
    (( elapsed >= MIN_SEC )) || exit 0

    # 同じプロンプトに対して二重に押し込まない
    marker="${prompt_id:-$started}"
    done_file="$STATE_DIR/$key.notified"
    if [[ -r "$done_file" ]] && [[ "$(<"$done_file")" == "$marker" ]]; then
      exit 0
    fi

    # このターン中に Claude が自分から PushNotification を呼んでいたら任せる
    if [[ -r "$tp" ]] && tail -n 40 "$tp" 2>/dev/null | grep -q 'PushNotification'; then
      printf '%s' "$marker" >"$done_file" 2>/dev/null || true
      exit 0
    fi

    printf '%s' "$marker" >"$done_file" 2>/dev/null || true

    cwd=$(jqr '.cwd')
    label=""
    [[ -n "$cwd" ]] && label=$(basename "$cwd")
    [[ -n "$label" ]] || label="${project:-task}"

    reason="[notify hook] このターンは ${elapsed} 秒かかった (作業ディレクトリ: ${label})。停止する前に PushNotification ツールを 1 回だけ呼び、200 文字以内・1 行・マークダウン無しで「${label} で何が終わったか」と「ユーザーが次に判断すべきことがあればそれ」を伝えろ (status: proactive)。ツール呼び出し以外の作業・説明・要約・謝罪は一切追加するな。送信したらそのまま停止してよい。ツールが 'Not sent' を返しても再送は不要。"

    jq -nc --arg reason "$reason" '{decision:"block", reason:$reason}'
    exit 0
    ;;

  notify)
    msg=$(jqr '.message')
    osc_notify "Claude Code: 要対応" "$(trunc "$msg" 100)"
    exit 0
    ;;
esac

exit 0
