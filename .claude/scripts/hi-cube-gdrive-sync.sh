#!/usr/bin/env bash
# hi-cube/ 配下が編集されたら、共有ドライブ「バックオフィス」へ自動同期する。
# PostToolUse (Write|Edit) フックから呼ばれる想定。stdin にツール呼び出しのJSONが来る。
set -uo pipefail

TARGET_DIR="/home/karinto/workspace/raim/hi-cube"
SYNC="$TARGET_DIR/sync_to_gdrive.py"
LOG="$TARGET_DIR/.gdrive_sync.log"
LOCK="$TARGET_DIR/.gdrive_sync.lock"

payload="$(cat)"
path="$(printf '%s' "$payload" | python3 -c \
  'import sys,json
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
ti = d.get("tool_input") or {}
print(ti.get("file_path") or ti.get("notebook_path") or "")' 2>/dev/null)"

# 対象ディレクトリ外なら何もしない
case "$path" in
  "$TARGET_DIR"/*) ;;
  *) exit 0 ;;
esac

[ -x "$(command -v python3)" ] || exit 0
[ -f "$SYNC" ] || exit 0

# 同期はネットワークを伴うのでバックグラウンドへ逃がし、多重起動は flock で防ぐ。
(
  flock -n 9 || exit 0
  {
    echo "=== $(date '+%F %T') triggered by: $path"
    python3 "$SYNC"
  } >>"$LOG" 2>&1
) 9>"$LOCK" &

exit 0
