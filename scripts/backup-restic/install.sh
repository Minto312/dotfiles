#!/usr/bin/env bash
# L1 (user 側) の systemd user timer を設置/撤去する。
#
#   backup-user   : 日次 17:30 UTC (= 02:30 JST)
#   maintain-user : 週次 土 15:00 UTC (= 日 00:00 JST)
#
# 時間帯は既存 timer とぶつけないように選んである:
#   resource-audit-collect 19:17 UTC / domain-monitor-audit 19:52 UTC (どちらも日次)
# I/O は gha-runner と NVMe を共有しているので idle クラスに落とす
#   (machine/troubleshooting/machine-slow-ci-io-contention.md)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

units=(backup-user.service backup-user.timer restic-maintain.service restic-maintain.timer
       backup-l3.service backup-l3.timer)

uninstall() {
  for u in backup-user.timer restic-maintain.timer backup-l3.timer; do
    systemctl --user disable --now "$u" 2>/dev/null || true
  done
  for u in "${units[@]}"; do rm -f "$UNIT_DIR/$u"; done
  systemctl --user daemon-reload
  echo "removed."
}

if [ "${1:-}" = "--uninstall" ]; then uninstall; exit 0; fi

mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/backup-user.service" <<EOF
[Unit]
Description=restic L1: develop の ~ を pve へバックアップ
Documentation=file://$HOME/workspace/machine/storage/backup-develop.md

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/backup-user.sh
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=6h
EOF

cat > "$UNIT_DIR/backup-user.timer" <<'EOF'
[Unit]
Description=restic L1 の日次実行 (17:30 UTC = 02:30 JST)

[Timer]
OnCalendar=*-*-* 17:30:00
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > "$UNIT_DIR/restic-maintain.service" <<EOF
[Unit]
Description=restic L1: prune と check
Documentation=file://$HOME/workspace/machine/storage/backup-develop.md

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/maintain-user.sh
Nice=15
IOSchedulingClass=idle
TimeoutStartSec=12h
EOF

cat > "$UNIT_DIR/restic-maintain.timer" <<'EOF'
[Unit]
Description=restic L1 保守の週次実行 (土 15:00 UTC = 日 00:00 JST)

[Timer]
OnCalendar=Sat *-*-* 15:00:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > "$UNIT_DIR/backup-l3.service" <<EOF
[Unit]
Description=restic L3: L1 リポジトリを個人 Google Drive へ複製 (オフサイト)
Documentation=file://$HOME/workspace/machine/storage/backup-develop.md

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/copy-l3.sh
Nice=15
IOSchedulingClass=idle
TimeoutStartSec=8h
EOF

cat > "$UNIT_DIR/backup-l3.timer" <<'EOF'
[Unit]
Description=restic L3 の日次実行 (18:30 UTC = 03:30 JST。L1 の後)

[Timer]
OnCalendar=*-*-* 18:30:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now backup-user.timer restic-maintain.timer backup-l3.timer

echo "installed:"
systemctl --user list-timers --all --no-pager backup-user.timer restic-maintain.timer backup-l3.timer
