#!/usr/bin/env bash
# Claude Code hook handler.
# Usage: notify.sh <event> <  <hook JSON on stdin>
#
# Events: start | stop | notify | prompt | pretool
#
# 役割:
# - OSC 777 (notify) エスケープを /dev/tty に出力 → wezterm が Windows 通知に変換
#
# (以前は zellij タブ名も書き換えていたが、hook 発火時の active タブが claude の
#  タブとは限らず、無関係なタブをリネームしてしまうため撤去した)

set -uo pipefail

event="${1:-}"
input=$(cat 2>/dev/null || true)

# OSC 777: rxvt-style notification escape (wezterm が OS 通知に変換)
# /dev/tty に書く必要あり (Claude が hook の stdout/stderr を捕捉する場合があるため)
osc_notify() {
  local title="$1" body="$2"
  printf '\e]777;notify;%s;%s\e\\' "$title" "$body" >/dev/tty 2>/dev/null || true
}

# 改行除去 + N 文字に切り詰め
trunc() { printf '%s' "$1" | tr '\n' ' ' | cut -c "1-${2:-30}"; }

case "$event" in
  stop)
    # transcript_path から「親ディレクトリ名」を抜いてプロジェクト名に
    tp=$(jq -r '.transcript_path // ""' <<<"$input")
    project=""
    if [[ -n "$tp" ]]; then
      project=$(basename "$(dirname "$tp")")
    fi
    osc_notify "Claude Code" "${project:-task} 完了"
    ;;

  notify)
    msg=$(jq -r '.message // ""' <<<"$input")
    osc_notify "Claude Code: 要対応" "$(trunc "$msg" 100)"
    ;;
esac
