#!/usr/bin/env bash
# mem-watch の systemd user unit を作って有効化する。
#
# unit を dotfiles で追跡しない (= .config/systemd/user/ は gitignore 済み) ので、
# feedscope と同じく install スクリプトで再生成する方針にしている。
#
#   ./install.sh            # 作って有効化
#   ./install.sh --uninstall  # 止めて消す (メモリを買ったら実行する)
set -euo pipefail

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SCRIPT="$HOME/dotfiles/scripts/mem-watch/mem-watch.py"

if [ "${1:-}" = "--uninstall" ]; then
  systemctl --user disable --now mem-watch.timer 2>/dev/null || true
  rm -f "$UNIT_DIR/mem-watch.service" "$UNIT_DIR/mem-watch.timer"
  systemctl --user daemon-reload
  echo "mem-watch を撤去した。state は ~/.local/state/mem-watch に残る"
  exit 0
fi

mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/mem-watch.service" <<EOF
[Unit]
Description=mem-watch: pve 増設用 DDR4 RDIMM の出物を探して Discord に流す
Documentation=file://%h/workspace/machine/infra/pve-memory-upgrade.md

[Service]
Type=oneshot
# webhook が無くてもユニットを落とさない ("-" 付き)。
# 後に読んだ方が勝つ。resource-audit と同じ develop チャンネルへ流す。
EnvironmentFile=-%h/.config/discord-notify/env
EnvironmentFile=-%h/.config/resource-audit/env
EnvironmentFile=-%h/.config/mem-watch/env
ExecStart=$SCRIPT
TimeoutStartSec=5min
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7

[Install]
WantedBy=default.target
EOF

cat > "$UNIT_DIR/mem-watch.timer" <<'EOF'
[Unit]
Description=Run mem-watch every 15 minutes

[Timer]
# 出物は数時間で売れるので短めに回す。
# ⚠ これ以上詰めると Yahoo 側に 429 で弾かれる (1 実行あたり 12 リクエスト)。
OnBootSec=3min
OnUnitActiveSec=15min
# :00 とぶつけない
RandomizedDelaySec=90
Unit=mem-watch.service

[Install]
WantedBy=timers.target
EOF

chmod +x "$SCRIPT"
systemctl --user daemon-reload
systemctl --user enable --now mem-watch.timer
echo "有効化した:"
systemctl --user list-timers mem-watch.timer --no-pager
