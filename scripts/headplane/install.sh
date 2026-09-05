#!/usr/bin/env bash
# headplane (headscale の web GUI) を SaaS 側 tailnet に出すための user unit を設置/撤去する。
#
#   hs-server 100.64.0.1:3000 ──ssh -L──> develop 127.0.0.1:5090 ──tailscale serve──>
#     https://headplane.halley-woodpecker.ts.net/admin
#
# 🔴 この unit が担うのは 1 本目 (ssh -L) だけ。
#    develop 自身は raim tailnet に居ない (居るのは raim-tailnet-proxy コンテナ) ので、
#    tailscale serve に直接 100.64.0.1:3000 を渡すことはできない。
#
# 2 本目 (Tailscale Services) は tailscaled が状態を持つので unit は要らない。
# 初回だけ以下を実行し、管理コンソールで Service 定義 + ノード承認を済ませる:
#
#   tailscale serve --service=svc:headplane --bg --yes 5090
#
#   ⚠ 承認前は `approval from an admin is required` が返る。承認後も反映に
#     ラグがあるので、通るまで数十秒おきに同じコマンドを打ち直す。
#   撤去は  tailscale serve clear svc:headplane
#
# ⚠ ポート 5090 は shared-browser の noVNC 帯 (5063 + slot) を避けてある。
#
# 詳細は machine/services/headscale.md と machine/network/tailscale.md
set -euo pipefail

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
PORT=${HEADPLANE_PORT:-5090}
HS_IP=${HEADPLANE_HS_IP:-100.64.0.1}
UNIT=headplane-forward.service

if [ "${1:-}" = "--uninstall" ]; then
  systemctl --user disable --now "$UNIT" 2>/dev/null || true
  rm -f "$UNIT_DIR/$UNIT"
  systemctl --user daemon-reload
  echo "removed $UNIT (tailscale serve は別途 clear すること)"
  exit 0
fi

mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/$UNIT" <<EOF
[Unit]
Description=headplane: hs-server:3000 を develop の 127.0.0.1:$PORT に出す
Documentation=file://$HOME/workspace/machine/services/headscale.md
After=network-online.target docker.service
Wants=network-online.target
# 失敗が続いても諦めない (raim-tailnet-proxy の復帰待ち)
StartLimitIntervalSec=0

[Service]
Type=simple
# ssh hs-server は raim-tailnet-proxy コンテナの SOCKS5 を ProxyCommand で通る。
# コンテナが落ちていると失敗するので、その間は再試行し続ける。
ExecStart=/usr/bin/ssh -N -o BatchMode=yes -o ControlPath=none \\
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \\
  -L 127.0.0.1:$PORT:$HS_IP:3000 hs-server
Restart=always
RestartSec=15s

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now "$UNIT"
echo "installed: $UNIT (port $PORT)"
