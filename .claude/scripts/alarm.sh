#!/bin/bash
# トースト通知：Windows 10/11のネイティブ通知（BurntToast使用）
#
# 使用方法:
#   alarm.sh [-t タイトル] [-m メッセージ] [--type success|warning|error|info]
#   echo '{"hook_event_name": "Stop"}' | alarm.sh
#
# hooksからはstdinでJSONが渡されます

set -euo pipefail

# デフォルト値
DEFAULT_TITLE="Claude Code"
DEFAULT_MESSAGE="タスクが完了しました"
DEFAULT_TYPE="info"

# 変数初期化
title=""
message=""
notify_type=""

# --- エラーハンドリング ---

# pwsh.exeの存在確認
if ! command -v pwsh.exe &> /dev/null; then
    echo "エラー: pwsh.exe が見つかりません。PowerShellをインストールしてください。" >&2
    exit 1
fi

# BurntToastモジュールの確認
check_burnttoast() {
    pwsh.exe -Command "if (-not (Get-Module -ListAvailable -Name BurntToast)) { exit 1 }" </dev/null 2>/dev/null
    return $?
}

if ! check_burnttoast; then
    echo "エラー: BurntToastモジュールがインストールされていません。" >&2
    echo "インストール: pwsh.exe -Command \"Install-Module -Name BurntToast -Force\"" >&2
    exit 1
fi

# --- 引数パース ---

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--title)
            title="$2"
            shift 2
            ;;
        -m|--message)
            message="$2"
            shift 2
            ;;
        --type)
            notify_type="$2"
            shift 2
            ;;
        -h|--help)
            echo "使用方法: alarm.sh [-t タイトル] [-m メッセージ] [--type success|warning|error|info]"
            echo ""
            echo "オプション:"
            echo "  -t, --title    通知のタイトル（デフォルト: $DEFAULT_TITLE）"
            echo "  -m, --message  通知のメッセージ（デフォルト: $DEFAULT_MESSAGE）"
            echo "  --type         通知タイプ: success, warning, error, info（デフォルト: $DEFAULT_TYPE）"
            echo ""
            echo "hooksからはstdinでJSONが渡され、hook_event_nameがタイトルに使用されます"
            exit 0
            ;;
        *)
            echo "不明なオプション: $1" >&2
            exit 1
            ;;
    esac
done

# --- stdinからJSON読み取り（hooksからの入力） ---

if [[ ! -t 0 ]]; then
    # stdinがパイプされている場合
    json_input=$(cat)
    if [[ -n "$json_input" ]]; then
        # jqが利用可能か確認
        if command -v jq &> /dev/null; then
            hook_event=$(echo "$json_input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
            if [[ -n "$hook_event" && -z "$title" ]]; then
                title="$hook_event"
            fi

            # transcript_pathからプロジェクト名を抽出
            transcript_path=$(echo "$json_input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
            if [[ -n "$transcript_path" && -z "$message" ]]; then
                # パス形式: ~/.claude/projects/home/user/project-name/session-id.jsonl
                # 最後から2階層のディレクトリを抽出
                project_dir=$(dirname "$transcript_path")
                project_name=$(basename "$project_dir")
                parent_dir=$(dirname "$project_dir")
                parent_name=$(basename "$parent_dir")
                if [[ -n "$project_name" ]]; then
                    message="$parent_name/$project_name"
                fi
            fi
        fi
    fi
fi

# --- デフォルト値適用 ---

title="${title:-$DEFAULT_TITLE}"
message="${message:-$DEFAULT_MESSAGE}"
notify_type="${notify_type:-$DEFAULT_TYPE}"

# --- 通知タイプに応じたアイコン設定 ---

get_sound_param() {
    case "$1" in
        success)
            echo "-Sound 'Call2'"
            ;;
        warning)
            echo "-Sound 'Alarm'"
            ;;
        error)
            echo "-Sound 'Alarm3'"
            ;;
        info|*)
            echo "-Sound 'Default'"
            ;;
    esac
}

sound_param=$(get_sound_param "$notify_type")

# --- 通知送信 ---

# シングルクォート内のエスケープ処理
escape_for_ps() {
    echo "$1" | sed "s/'/''/g"
}

escaped_title=$(escape_for_ps "$title")
escaped_message=$(escape_for_ps "$message")

pwsh.exe -Command "New-BurntToastNotification -Text '$escaped_title', '$escaped_message' $sound_param"
