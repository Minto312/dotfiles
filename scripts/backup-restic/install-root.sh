#!/usr/bin/env bash
# L1 の root 側を設置する。sudo で 1 回だけ実行する。
#
#   sudo ~/dotfiles/scripts/backup-restic/install-root.sh
#
# やること:
#   1. restic を /usr/local/bin へ (root の PATH から見えるように)
#   2. スクリプトを /usr/local/lib/backup-restic/ へ複製 (ユーザーの home に依存させない)
#   3. root 用の SSH 鍵と ssh_config を用意 (鍵は karinto のものを複製 = pve 側の変更が不要)
#   4. root リポジトリ専用のパスワードを生成 (user 側とは別にする)
#   5. restic init
#   6. systemd system unit + timer を設置 (日次 18:00 UTC = 03:00 JST)
#
# --uninstall で撤去する。

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then echo "sudo で実行してください" >&2; exit 1; fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR=/usr/local/lib/backup-restic
USER_HOME="$(getent passwd "${SUDO_USER:-karinto}" | cut -d: -f6)"
REPO="sftp:pve-backup:/rpool/backup/develop-root"
PWFILE=/root/.restic/develop-root.pass

if [ "${1:-}" = "--uninstall" ]; then
  systemctl disable --now backup-root.timer 2>/dev/null || true
  rm -f /etc/systemd/system/backup-root.service /etc/systemd/system/backup-root.timer
  systemctl daemon-reload
  rm -rf "$DEST_DIR"
  echo "removed (鍵とパスワードとリポジトリは残してあります)"
  exit 0
fi

# 1. restic
if [ ! -x /usr/local/bin/restic ]; then
  install -m 755 "$USER_HOME/.local/bin/restic" /usr/local/bin/restic
fi
echo "restic: $(/usr/local/bin/restic version)"

# 2. スクリプト
install -d -m 755 "$DEST_DIR"
install -m 755 "$SRC_DIR/backup-root.sh"    "$DEST_DIR/backup-root.sh"
install -m 644 "$SRC_DIR/excludes-root.txt" "$DEST_DIR/excludes-root.txt"

# 3. SSH (karinto の鍵を複製する。pve 側の authorized_keys は develop の IP で制限済み)
install -d -m 700 /root/.ssh
if [ ! -f /root/.ssh/id_ed25519_restic_pve ]; then
  install -m 600 "$USER_HOME/.ssh/id_ed25519_restic_pve" /root/.ssh/id_ed25519_restic_pve
fi
if ! grep -qE '^Host pve-backup$' /root/.ssh/config 2>/dev/null; then
  cat >> /root/.ssh/config <<'EOF'

Host pve-backup
    HostName 192.168.1.10
    User resticbk
    IdentityFile /root/.ssh/id_ed25519_restic_pve
    IdentitiesOnly yes
    Compression no
    ServerAliveInterval 60
EOF
  chmod 600 /root/.ssh/config
fi
# host key を known_hosts に入れておく (BatchMode で詰まらないように)
ssh-keyscan -H 192.168.1.10 >> /root/.ssh/known_hosts 2>/dev/null
sort -u -o /root/.ssh/known_hosts /root/.ssh/known_hosts

# 4. パスワード (user 側とは別にする。root リポジトリの中身の方が機微なため)
install -d -m 700 /root/.restic
if [ ! -s "$PWFILE" ]; then
  openssl rand -base64 48 | tr -d '\n' > "$PWFILE"
  chmod 600 "$PWFILE"
  echo "🔴 root リポジトリのパスワードを生成しました: $PWFILE"
  echo "🔴 develop の外へ退避してください。失うと復号できません。"
fi

# 5. init (既に有るなら何もしない)
export RESTIC_REPOSITORY="$REPO" RESTIC_PASSWORD_FILE="$PWFILE" RESTIC_CACHE_DIR=/var/cache/restic
install -d -m 700 /var/cache/restic
if /usr/local/bin/restic cat config >/dev/null 2>&1; then
  echo "repository: already initialized"
else
  /usr/local/bin/restic init
fi

# 6. systemd
cat > /etc/systemd/system/backup-root.service <<EOF
[Unit]
Description=restic L1 (root): /etc, docker volumes, tailscale を pve へ
Documentation=file://$USER_HOME/workspace/machine/storage/backup-develop.md

[Service]
Type=oneshot
ExecStart=$DEST_DIR/backup-root.sh
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=6h
EOF

cat > /etc/systemd/system/backup-root.timer <<'EOF'
[Unit]
Description=restic L1 (root) の日次実行 (18:00 UTC = 03:00 JST)

[Timer]
OnCalendar=*-*-* 18:00:00
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now backup-root.timer

echo
echo "installed:"
systemctl list-timers --all --no-pager backup-root.timer
